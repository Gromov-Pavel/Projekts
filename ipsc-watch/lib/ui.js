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
