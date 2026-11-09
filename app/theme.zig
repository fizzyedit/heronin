//! Heronin's light palette. Nunito is supplied by fizzy; no app font assets.
const dvui = @import("dvui");
pub const Color = dvui.Color;
pub const paper = c(0xF5EBDF);
pub const card = c(0xFFFAF2);
pub const ink = c(0x2B1D12);
pub const border = c(0xD9C7A8);
pub const chip = c(0xE8D5B8);
pub const tab_off_ink = c(0x6B5238);
pub const orange: [3]Color = .{ c(0xBC5B22), c(0xC8683B), c(0xDA8A5E) };
pub const red: [3]Color = .{ c(0x7A322D), c(0x9A4943), c(0xB85650) };
pub const mustard: [3]Color = .{ c(0xC08B26), c(0xD49A2C), c(0xE8A838) };
pub const brown: [3]Color = .{ c(0x67482C), c(0x7D5636), c(0x97704A) };
pub const olive: [3]Color = .{ c(0x796123), c(0x8A702A), c(0xAB8E3A) };
pub const washes: [6]Color = .{ c(0xF3D9C6), c(0xF4E3B8), c(0xE6DDC8), c(0xF6E4A8), c(0xE8E0D0), c(0xEBD2C4) };
pub const Status = struct { fill: Color, ink: Color };
pub const tagged: Status = .{ .fill = olive[0], .ink = card };
pub const review: Status = .{ .fill = orange[0], .ink = card };
pub const working: Status = .{ .fill = mustard[0], .ink = ink };
pub const waiting: Status = .{ .fill = chip, .ink = brown[0] };
pub const other: Status = .{ .fill = brown[0], .ink = card };
pub const failed: Status = .{ .fill = brown[0], .ink = card };
pub const species_face = "Nunito"; // TODO(font): Zilla Slab for species names, a later job adds the asset
pub const body_face = "Nunito";
pub const title_face = "Nunito";
fn c(hex: u24) Color {
    return .{ .r = @intCast(hex >> 16), .g = @intCast((hex >> 8) & 255), .b = @intCast(hex & 255), .a = 255 };
}
fn style(fill: Color, text: Color, edge: Color) dvui.Theme.Style {
    return .{ .fill = fill, .fill_hover = fill, .fill_press = fill, .text = text, .text_hover = text, .text_press = text, .border = edge };
}
/// Retain the host's embedded font sources; replace all visual and font roles.
pub fn light(base: dvui.Theme) dvui.Theme {
    var t = base;
    t.name = "Heronin";
    t.dark = false;
    t.fill = paper;
    t.fill_hover = paper;
    t.fill_press = paper;
    t.text = ink;
    t.text_hover = ink;
    t.text_press = ink;
    t.border = border;
    t.focus = orange[0];
    t.text_select = chip;
    t.window = style(paper, ink, border);
    t.control = style(card, ink, border);
    t.highlight = style(orange[0], card, brown[0]);
    t.err = style(failed.fill, failed.ink, brown[0]);
    t.app1 = style(red[0], card, brown[0]);
    t.app2 = style(olive[0], card, brown[0]);
    t.app3 = style(mustard[0], ink, brown[0]);
    t.font_body = .find(.{ .family = body_face, .size = 16 });
    t.font_title = .find(.{ .family = title_face, .size = 28, .weight = .bold });
    t.font_heading = .find(.{ .family = title_face, .size = 18, .weight = .bold });
    t.font_mono = t.font_body;
    t.corner = .round(0);
    return t;
}
