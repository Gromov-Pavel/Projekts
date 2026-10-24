package app.pace.ipsc_training

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Zepp Side Service talks only to this phone's loopback interface. */
class WatchPhoneBridge(messenger: BinaryMessenger) {
    companion object { const val PORT = 19373 }
    private val main = Handler(Looper.getMainLooper())
    private val random = SecureRandom()
    @Volatile private var epoch = 0
    @Volatile private var server: ServerSocket? = null
    private var sink: EventChannel.EventSink? = null
    private var peer: String? = null
    private var peerCode = 0
    private var session = ""
    private var approved = false
    private var lastCommand = 0
    private var lastSeen = 0L
    private var snapshot = ByteArray(20).also { it[0] = 1; it[1] = 4 }
    private data class Reply(val status: Int, val body: JSONObject)

    init {
        EventChannel(messenger, "ipsc/watch-events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
            override fun onCancel(arguments: Any?) { sink = null; close() }
        })
        MethodChannel(messenger, "ipsc/watch").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> { start(); result.success(null) }
                    "stop" -> { close(); result.success(null) }
                    "approve" -> {
                        expirePeer()
                        check(peer != null && peer == call.argument<String>("peer")) { "Часы уже отключились" }
                        check(peerCode == call.argument<Int>("code")) { "Код подключения изменился" }
                        approved = true
                        Log.i("IPSCWatch", "Zepp watch approved")
                        result.success(null)
                    }
                    "publish" -> {
                        val bytes = call.arguments as? ByteArray
                        require(bytes != null && bytes.size == 20 && bytes[0].toInt() == 1)
                        snapshot = bytes.copyOf(); result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("watch", e.message, null) }
        }
    }
    private fun event(kind: String) {
        sink?.success(mapOf("event" to kind, "peer" to peer, "code" to peerCode))
    }
    private fun start() {
        check(server == null) { "Связь уже включена" }
        val socket = ServerSocket()
        try { socket.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT), 4) }
        catch (e: Exception) { socket.close(); throw e }
        server = socket
        val cycle = ++epoch
        Thread({
            while (server === socket && cycle == epoch) {
                try { socket.accept().use { serve(it, cycle) } }
                catch (_: Exception) { if (cycle != epoch) break }
            }
        }, "IPSC-Zepp-loopback").apply { isDaemon = true; start() }
        main.post(object : Runnable {
            override fun run() {
                if (cycle != epoch || server == null) return
                expirePeer(); main.postDelayed(this, 2000)
            }
        })
        Log.i("IPSCWatch", "Zepp loopback bridge started")
    }
    private fun expirePeer() {
        if (peer != null && SystemClock.elapsedRealtime() - lastSeen > 6000) {
            peer = null; approved = false; peerCode = 0; session = ""; lastCommand = 0
            event("disconnected")
        }
    }
    private fun error(status: Int, message: String) = Reply(status, JSONObject().put("error", message))
    private fun handle(method: String, path: String, client: String, authSession: String, bytes: ByteArray?): Reply {
        expirePeer()
        if (!client.matches(Regex("[0-9a-f]{32}"))) return error(400, "Неверный запрос Zepp")
        if (method == "GET" && path == "/v1/state") {
            if (peer != null && peer != client) return error(409, "Дождитесь завершения предыдущей связи")
            if (peer == null) {
                peer = client; approved = false; lastCommand = 0
                peerCode = random.nextInt(900000) + 100000
                session = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it.toInt() and 255) }
                Log.i("IPSCWatch", "Zepp side service connected; confirmation required")
                event("peer")
            }
            lastSeen = SystemClock.elapsedRealtime()
            val packet = if (approved) snapshot else ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
                .put(1.toByte()).put(4.toByte()).putShort(0).putInt(peerCode).putInt(0).putInt(0).putInt(-1).array()
            return Reply(200, JSONObject().put("session", session)
                .put("packet", JSONArray(packet.map { it.toInt() and 255 })))
        }
        if (method == "POST" && path == "/v1/command") {
            if (!approved || peer != client || authSession != session) return error(403, "Подтвердите код на телефоне")
            if (bytes == null || bytes.size != 12 || bytes[0].toInt() != 1 || bytes[1].toInt() !in 1..2)
                return error(400, "Неверная команда")
            val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val id = data.getShort(2).toInt() and 65535
            if (id <= lastCommand || sink == null) return error(409, "Устаревшая команда")
            lastSeen = SystemClock.elapsedRealtime(); lastCommand = id
            sink?.success(mapOf("event" to "command", "op" to bytes[1].toInt(),
                "run" to (data.getInt(4).toLong() and 0xffffffffL)))
            return Reply(202, JSONObject().put("accepted", true))
        }
        return error(404, "Неизвестный запрос")
    }
    private fun readLine(input: InputStream): String {
        val bytes = ArrayList<Byte>()
        while (bytes.size < 2048) {
            val value = input.read()
            require(value >= 0) { "Incomplete HTTP request" }
            if (value == 10) return bytes.toByteArray().toString(Charsets.US_ASCII).trimEnd('\r')
            bytes.add(value.toByte())
        }
        throw IllegalArgumentException("HTTP line too long")
    }
    private fun serve(socket: Socket, cycle: Int) {
        socket.soTimeout = 2000
        val reply = try {
            val input = socket.getInputStream()
            val request = readLine(input).split(' ')
            require(request.size == 3 && request[2] == "HTTP/1.1")
            val headers = mutableMapOf<String, String>()
            var headerBytes = 0
            while (true) {
                val line = readLine(input)
                if (line.isEmpty()) break
                headerBytes += line.length
                require(headerBytes <= 8192 && headers.size < 32)
                val colon = line.indexOf(':'); require(colon > 0)
                headers[line.substring(0, colon).lowercase()] = line.substring(colon + 1).trim()
            }
            require(headers["x-ipsc-bridge"] == "1")
            val length = headers["content-length"]?.toInt() ?: 0
            require(length in 0..1024)
            val body = ByteArray(length)
            var offset = 0
            while (offset < length) {
                val n = input.read(body, offset, length - offset); require(n > 0); offset += n
            }
            val packet = if (length > 0) {
                val list = JSONObject(body.toString(Charsets.UTF_8)).getJSONArray("packet")
                require(list.length() == 12)
                ByteArray(12) { i ->
                    val value = list.get(i); require(value is Int && value in 0..255); value.toByte()
                }
            } else null
            val response = AtomicReference<Reply>()
            val done = CountDownLatch(1)
            val canceled = AtomicBoolean(false)
            main.post {
                try {
                    response.set(if (!canceled.get() && cycle == epoch && server != null)
                        handle(request[0], request[1], headers["x-ipsc-client"] ?: "", headers["x-ipsc-session"] ?: "", packet)
                        else error(503, "Включите связь с часами"))
                } catch (_: Exception) { response.set(error(400, "Неверный запрос")) }
                finally { done.countDown() }
            }
            if (done.await(2, TimeUnit.SECONDS)) response.get() else { canceled.set(true); error(503, "Телефон занят") }
        } catch (_: Exception) { error(400, "Неверный запрос") }
        val data = reply.body.toString().toByteArray(Charsets.UTF_8)
        val header = "HTTP/1.1 ${reply.status} IPSC\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${data.size}\r\nConnection: close\r\n\r\n"
        socket.getOutputStream().apply { write(header.toByteArray(Charsets.US_ASCII)); write(data); flush() }
    }
    fun close() {
        ++epoch
        val socket = server; server = null
        try { socket?.close() } catch (_: Exception) {}
        peer = null; approved = false; peerCode = 0; session = ""; lastCommand = 0
        Log.i("IPSCWatch", "Zepp loopback bridge closed")
    }
}
