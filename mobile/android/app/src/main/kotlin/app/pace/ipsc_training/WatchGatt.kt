package app.pace.ipsc_training

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/** An opt-in, encrypted BLE peripheral. Each connection needs approval on the phone. */
class WatchGatt(private val context: Context, messenger: BinaryMessenger) {
    companion object {
        val SERVICE: UUID = UUID.fromString("dfc00001-8e4f-4d3c-9628-37cf53e51b18")
        val STATE: UUID = UUID.fromString("dfc00002-8e4f-4d3c-9628-37cf53e51b18")
        val COMMAND: UUID = UUID.fromString("dfc00003-8e4f-4d3c-9628-37cf53e51b18")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null
    private var epoch = 0
    private var advertising: AdvertiseCallback? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var pending: MethodChannel.Result? = null
    private var sink: EventChannel.EventSink? = null
    private var peer: BluetoothDevice? = null
    private var approved = false
    private var peerCode = 0
    private var lastCommand = 0
    private var subscribed = false
    private var notifying = false
    private var dirty = false
    private var snapshot = ByteArray(20).also { it[0] = 1; it[1] = 4 }

    init {
        EventChannel(messenger, "ipsc/watch-events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
            override fun onCancel(arguments: Any?) { sink = null; close() }
        })
        MethodChannel(messenger, "ipsc/watch").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> start(result)
                    "stop" -> { close(); result.success(null) }
                    "approve" -> {
                        check(peer != null && peer?.address == call.argument<String>("peer")) { "Часы уже отключились" }
                        check(peerCode == call.argument<Int>("code")) { "Код подключения изменился" }
                        if (!approved) { approved = true; lastCommand = 0 }
                        result.success(null)
                    }
                    "publish" -> {
                        val bytes = call.arguments as? ByteArray
                        require(bytes != null && bytes.size == 20 && bytes[0].toInt() == 1)
                        snapshot = bytes.copyOf(); notifyState(); result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("watch", e.message, null) }
        }
    }
    private fun event(kind: String, message: String? = null) {
        sink?.success(mapOf("event" to kind, "peer" to peer?.address, "code" to peerCode, "message" to message))
    }
    private fun start(result: MethodChannel.Result) {
        check(server == null && pending == null) { "Связь уже включена" }
        if (Build.VERSION.SDK_INT >= 31) {
            check(context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED &&
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) { "Разрешите Bluetooth" }
        }
        val adapter = manager.adapter
        check(adapter?.isEnabled == true) { "Включите Bluetooth" }
        advertiser = adapter.bluetoothLeAdvertiser
        check(advertiser != null) { "Телефон не поддерживает BLE advertising" }
        val cycle = ++epoch
        advertising = advertisingCallbacks(cycle)
        val gatt = manager.openGattServer(context, callbacks(cycle))
            ?: throw IllegalStateException("Не удалось открыть GATT")
        server = gatt; pending = result
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val state = BluetoothGattCharacteristic(STATE,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED)
        state.addDescriptor(BluetoothGattDescriptor(CCCD,
            BluetoothGattDescriptor.PERMISSION_READ_ENCRYPTED or BluetoothGattDescriptor.PERMISSION_WRITE_ENCRYPTED))
        service.addCharacteristic(state)
        service.addCharacteristic(BluetoothGattCharacteristic(COMMAND,
            BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED))
        if (!gatt.addService(service)) { fail("Не удалось добавить BLE service"); return }
        main.postDelayed({ if (cycle == epoch && pending != null) fail("Bluetooth не ответил за 10 секунд") }, 10000)
    }
    private fun fail(message: String) {
        val result = pending; pending = null
        close(); result?.error("watch", message, null)
        event("error", message)
    }
    private fun advertisingCallbacks(cycle: Int) = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            main.post { if (cycle == epoch) { pending?.success(null); pending = null } }
        }
        override fun onStartFailure(errorCode: Int) { main.post { if (cycle == epoch) fail("Advertising: $errorCode") } }
    }
    private fun callbacks(cycle: Int) = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            main.post {
                if (cycle != epoch) return@post
                if (server == null || pending == null) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) { fail("GATT service: $status"); return@post }
                try {
                    advertiser?.startAdvertising(AdvertiseSettings.Builder()
                        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                        .setConnectable(true).setTimeout(0).build(),
                        AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(), advertising)
                } catch (e: Exception) { fail(e.message ?: "Advertising failed") }
            }
        }
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            main.post {
                if (cycle != epoch) return@post
                val gatt = server ?: return@post
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    if (peer != null && peer?.address != device.address) {
                        try { gatt.cancelConnection(device) } catch (_: SecurityException) {}
                        return@post
                    }
                    peer = device; approved = false; lastCommand = 0
                    peerCode = java.security.SecureRandom().nextInt(900000) + 100000
                    subscribed = false; notifying = false; dirty = false; event("peer")
                } else if (peer?.address == device.address) {
                    peer = null; approved = false; lastCommand = 0
                    peerCode = 0
                    subscribed = false; notifying = false; dirty = false; event("disconnected")
                }
            }
        }
        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int,
                                                  characteristic: BluetoothGattCharacteristic) {
            main.post {
                if (cycle != epoch) return@post
                val gatt = server ?: return@post
                val bytes = if (approved) snapshot else ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
                    .put(1.toByte()).put(4.toByte()).putShort(0).putInt(peerCode).putInt(0).putInt(0).putInt(-1).array()
                val status = when {
                    peer?.address != device.address -> BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION
                    characteristic.uuid != STATE -> BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED
                    offset !in 0..bytes.size -> BluetoothGatt.GATT_INVALID_OFFSET
                    else -> BluetoothGatt.GATT_SUCCESS
                }
                respond(device, requestId, status, offset,
                    if (status == BluetoothGatt.GATT_SUCCESS) bytes.copyOfRange(offset, bytes.size) else null)
            }
        }
        override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int,
            characteristic: BluetoothGattCharacteristic, preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray) {
            val bytes = value.copyOf()
            main.post {
                if (cycle != epoch) return@post
                val gatt = server ?: return@post
                var code = BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED
                if (!approved || peer?.address != device.address) code = BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION
                else if (characteristic.uuid == COMMAND && !preparedWrite && offset == 0 && bytes.size == 12 &&
                    bytes[0].toInt() == 1 && bytes[1].toInt() in 1..2) {
                    val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                    val id = data.getShort(2).toInt() and 0xffff
                    if (id > lastCommand && sink != null) {
                        lastCommand = id; code = BluetoothGatt.GATT_SUCCESS
                        sink?.success(mapOf("event" to "command", "op" to bytes[1].toInt(),
                            "run" to (data.getInt(4).toLong() and 0xffffffffL)))
                    }
                }
                if (responseNeeded) respond(device, requestId, code, offset, null)
            }
        }
        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int,
            descriptor: BluetoothGattDescriptor, preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray) {
            val bytes = value.copyOf()
            main.post {
                if (cycle != epoch) return@post
                val gatt = server ?: return@post
                val valid = descriptor.uuid == CCCD && descriptor.characteristic.uuid == STATE &&
                    !preparedWrite && offset == 0 && bytes.size == 2 && bytes[1].toInt() == 0 && bytes[0].toInt() in 0..1
                val status = when {
                    !approved || peer?.address != device.address -> BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION
                    !valid -> BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED
                    else -> { subscribed = bytes[0].toInt() == 1; BluetoothGatt.GATT_SUCCESS }
                }
                if (responseNeeded) respond(device, requestId, status, offset, null)
                if (status == BluetoothGatt.GATT_SUCCESS) notifyState()
            }
        }
        override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int,
                                               descriptor: BluetoothGattDescriptor) {
            main.post {
                if (cycle != epoch || server == null) return@post
                val status = when {
                    !approved || peer?.address != device.address -> BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION
                    descriptor.uuid != CCCD || descriptor.characteristic.uuid != STATE -> BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED
                    offset !in 0..2 -> BluetoothGatt.GATT_INVALID_OFFSET
                    else -> BluetoothGatt.GATT_SUCCESS
                }
                val value = byteArrayOf(if (subscribed) 1.toByte() else 0.toByte(), 0)
                respond(device, requestId, status, offset,
                    if (status == BluetoothGatt.GATT_SUCCESS) value.copyOfRange(offset, value.size) else null)
            }
        }
        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                if (cycle != epoch) return@post
                if (peer?.address != device.address) return@post
                notifying = false
                if (dirty) { dirty = false; notifyState() }
            }
        }
    }
    private fun respond(device: BluetoothDevice, id: Int, status: Int, offset: Int, value: ByteArray?) {
        try { server?.sendResponse(device, id, status, offset, value) }
        catch (e: SecurityException) { close(); event("error", "Разрешение Bluetooth отозвано") }
    }
    @Suppress("DEPRECATION")
    private fun notifyState() {
        if (!approved || !subscribed) return
        if (notifying) { dirty = true; return }
        val gatt = server ?: return
        val device = peer ?: return
        val state = gatt.getService(SERVICE)?.getCharacteristic(STATE) ?: return
        try {
            notifying = if (Build.VERSION.SDK_INT >= 33)
                gatt.notifyCharacteristicChanged(device, state, false, snapshot.copyOf()) == 0
            else { state.value = snapshot.copyOf(); gatt.notifyCharacteristicChanged(device, state, false) }
        } catch (e: Exception) { notifying = false; event("error", e.message) }
    }
    fun close() {
        epoch++
        val result = pending; pending = null
        result?.error("watch", "Подключение отменено", null)
        try { advertising?.let { advertiser?.stopAdvertising(it) } } catch (_: Exception) {}
        try { server?.close() } catch (_: Exception) {}
        server = null; advertiser = null; peer = null; approved = false; lastCommand = 0
        peerCode = 0
        subscribed = false; notifying = false; dirty = false
        advertising = null
    }
}
