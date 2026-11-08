const model = @import("model");
const std = @import("std");

pub const table = [_]model.Species{
    .{ .code = "grbher3", .common = "Great Blue Heron", .scientific = "Ardea herodias", .family = "Ardeidae", .order = "Pelecaniformes" },
    .{ .code = "greegr", .common = "Great Egret", .scientific = "Ardea alba", .family = "Ardeidae", .order = "Pelecaniformes" },
    .{ .code = "norcar", .common = "Northern Cardinal", .scientific = "Cardinalis cardinalis", .family = "Cardinalidae", .order = "Passeriformes" },
    .{ .code = "blujay", .common = "Blue Jay", .scientific = "Cyanocitta cristata", .family = "Corvidae", .order = "Passeriformes" },
    .{ .code = "amerob", .common = "American Robin", .scientific = "Turdus migratorius", .family = "Turdidae", .order = "Passeriformes" },
    .{ .code = "mallar3", .common = "Mallard", .scientific = "Anas platyrhynchos", .family = "Anatidae", .order = "Anseriformes" },
    .{ .code = "rewbla", .common = "Red-winged Blackbird", .scientific = "Agelaius phoeniceus", .family = "Icteridae", .order = "Passeriformes" },
    .{ .code = "dowwoo", .common = "Downy Woodpecker", .scientific = "Dryobates pubescens", .family = "Picidae", .order = "Piciformes" },
    .{ .code = "bkcchi", .common = "Black-capped Chickadee", .scientific = "Poecile atricapillus", .family = "Paridae", .order = "Passeriformes" },
    .{ .code = "amegfi", .common = "American Goldfinch", .scientific = "Spinus tristis", .family = "Fringillidae", .order = "Passeriformes" },
    .{ .code = "belkin1", .common = "Belted Kingfisher", .scientific = "Megaceryle alcyon", .family = "Alcedinidae", .order = "Coraciiformes" },
    .{ .code = "osprey", .common = "Osprey", .scientific = "Pandion haliaetus", .family = "Pandionidae", .order = "Accipitriformes" },
};

pub fn find(code: []const u8) ?model.Species {
    for (table) |species| if (std.mem.eql(u8, species.code, code)) return species;
    return null;
}
