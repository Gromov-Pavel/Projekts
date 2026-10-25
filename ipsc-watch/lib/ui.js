import * as ui from '@zos/ui'
export function label(text, x, y, w, h, size, color = 0xffffff) {
  return ui.createWidget(ui.widget.TEXT, { x, y, w, h, text, text_size: size,
    color, align_h: ui.align.CENTER_H, align_v: ui.align.CENTER_V })
}
export function button(text, x, y, w, h, click) {
  return ui.createWidget(ui.widget.BUTTON, { x, y, w, h, text, text_size: 22,
    radius: 18, normal_color: 0x202b36, press_color: 0x36485a,
    color: 0xffffff, click_func: click })
}
export function update(widget, text) { widget.setProperty(ui.prop.TEXT, text) }

export function actionButton(text, click) {
  return ui.createWidget(ui.widget.BUTTON, { x: 0, y: 366, w: 480, h: 114,
    text, text_size: 30, radius: 0, normal_color: 0x202b36, press_color: 0x36485a,
    color: 0xffffff, click_func: click })
}
export function actionColor(widget, stop, ready) {
  widget.setProperty(ui.prop.MORE, {normal_color: stop ? 0xc62828 : ready ? 0x16733b : 0x202b36,
    press_color: stop ? 0x921e1e : ready ? 0x10582d : 0x36485a})
}

export function settingsIcon(click) {
  const icon = label('⚙', 184, 12, 112, 90, 76)
  icon.addEventListener(ui.event.CLICK_UP, click)
  return icon
}

export function show(widget, visible) { widget.setProperty(ui.prop.VISIBLE, visible) }
