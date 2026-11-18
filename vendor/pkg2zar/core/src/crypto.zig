// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-FileCopyrightText: 2026 ps4-pkg2zar contributors
// SPDX-License-Identifier: GPL-3.0-or-later

//! Crypto primitives the pkg format needs: AES-128-CBC, AES-128-XTS in the pkg flavour,
//! RSA PKCS#1 v1.5 private-key decrypt, SHA-256 and HMAC-SHA256.
//! Ported behaviour from shadPS4 crypto.cpp (GPL-2.0-or-later); all of it on zig std.

const std = @import("std");
const keys = @import("keys.zig");

pub const KeySet = struct {
    modulus: []const u8,
    private_exponent: []const u8,
};

pub const pkg_key_set: KeySet = .{
    .modulus = &keys.pkg_derived_key3_keyset.modulus,
    .private_exponent = &keys.pkg_derived_key3_keyset.private_exponent,
};

pub const fake_key_set: KeySet = .{
    .modulus = &keys.fake_keyset.modulus,
    .private_exponent = &keys.fake_keyset.private_exponent,
};

pub const RsaError = error{
    CiphertextWrongLength,
    BadPadding,
    ModularExponentiationFailed,
};

const rsa_bits = 2048;
const rsa_bytes = rsa_bits / 8;

/// PKCS#1 v1.5 private-key operation. Returns the padded-free message in `out`.
pub fn rsaPkcs1v15Decrypt(key: KeySet, ciphertext: []const u8, out: []u8) RsaError![]u8 {
    if (ciphertext.len != rsa_bytes) return error.CiphertextWrongLength;

    const Modulus = std.crypto.ff.Modulus(rsa_bits);
    const Fe = Modulus.Fe;

    const modulus = Modulus.fromBytes(key.modulus, .big) catch return error.ModularExponentiationFailed;
    const c = Fe.fromBytes(modulus, ciphertext, .big) catch return error.ModularExponentiationFailed;
    const m = modulus.powWithEncodedExponent(c, key.private_exponent, .big) catch
        return error.ModularExponentiationFailed;

    var em: [rsa_bytes]u8 = undefined;
    m.toBytes(&em, .big) catch return error.ModularExponentiationFailed;

    // EM = 0x00 || 0x02 || PS (>= 8 non-zero bytes) || 0x00 || M
    if (em[0] != 0x00 or em[1] != 0x02) return error.BadPadding;
    var sep: usize = 2;
    while (sep < em.len and em[sep] != 0x00) : (sep += 1) {}
    if (sep < 10 or sep == em.len) return error.BadPadding;

    const msg = em[sep + 1 ..];
    if (msg.len > out.len) return error.BadPadding;
    @memcpy(out[0..msg.len], msg);
    return out[0..msg.len];
}

/// AES-128-CBC decrypt in place, no padding handling. `src` and `dst` must be equal length
/// and a multiple of 16.
pub fn aesCbcDecrypt(key: [16]u8, iv: [16]u8, src: []const u8, dst: []u8) void {
    std.debug.assert(src.len == dst.len and src.len % 16 == 0);
    const ctx = std.crypto.core.aes.Aes128.initDec(key);
    var prev = iv;
    var i: usize = 0;
    while (i < src.len) : (i += 16) {
        var block: [16]u8 = undefined;
        ctx.decrypt(&block, src[i..][0..16]);
        for (0..16) |b| dst[i + b] = block[b] ^ prev[b];
        prev = src[i..][0..16].*;
    }
}

/// Pkg-flavoured AES-128-XTS. The tweak is AES(tweak_key, sector_le_u64) and is multiplied
/// by alpha between blocks within one sector. `src.len` must be a multiple of 16.
pub fn xtsDecrypt(data_key: [16]u8, tweak_key: [16]u8, sector: u64, src: []const u8, dst: []u8) void {
    std.debug.assert(src.len == dst.len and src.len % 16 == 0);
    const data_ctx = std.crypto.core.aes.Aes128.initDec(data_key);
    const tweak_ctx = std.crypto.core.aes.Aes128.initEnc(tweak_key);

    var sector_block: [16]u8 = @splat(0);
    std.mem.writeInt(u64, sector_block[0..8], sector, .little);
    var tweak: [16]u8 = undefined;
    tweak_ctx.encrypt(&tweak, &sector_block);

    var i: usize = 0;
    while (i < src.len) : (i += 16) {
        var x: [16]u8 = undefined;
        for (0..16) |b| x[b] = src[i + b] ^ tweak[b];
        var p: [16]u8 = undefined;
        data_ctx.decrypt(&p, &x);
        for (0..16) |b| dst[i + b] = p[b] ^ tweak[b];
        xtsMultiply(&tweak);
    }
}

fn xtsMultiply(t: *[16]u8) void {
    var carry: u8 = 0;
    for (0..16) |i| {
        const next: u8 = t[i] >> 7;
        t[i] = (t[i] << 1) | carry;
        carry = next;
    }
    if (carry != 0) t[0] ^= 0x87;
}

pub fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

pub fn hmacSha256(key: []const u8, data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data, key);
    return out;
}

test "aes-128-cbc decrypt matches the NIST SP 800-38A vector" {
    const key = [_]u8{ 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c };
    const iv = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const cipher = [_]u8{ 0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46, 0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9, 0x19, 0x7d };
    var plain: [16]u8 = undefined;
    aesCbcDecrypt(key, iv, &cipher, &plain);
    const expected = [_]u8{ 0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a };
    try std.testing.expectEqualSlices(u8, &expected, &plain);
}

test "xts decrypt matches a fixture sector from test-rom" {
    // Sector 0 of the base Terraria sample, verified against the reference implementation.
    const data_key = [_]u8{ 0xae, 0xf2, 0x00, 0x52, 0x76, 0xa1, 0xc9, 0xe3, 0x06, 0x56, 0x8c, 0x80, 0x9b, 0xaa, 0xb3, 0xab };
    const tweak_key = [_]u8{ 0xe5, 0x4b, 0xda, 0x54, 0x54, 0xeb, 0x52, 0xd0, 0x6d, 0x6e, 0x4f, 0xbc, 0x03, 0xa1, 0xcf, 0xef };
    const cipher = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b, 0x2a, 0x33, 0x01, 0x00, 0x00, 0x00, 0x00 };
    const expected = [_]u8{ 0x35, 0xac, 0xec, 0xdb, 0x04, 0x2d, 0x80, 0x80, 0xd8, 0xfe, 0x18, 0x69, 0xbf, 0x3c, 0x6b, 0xa5 };
    var plain: [16]u8 = undefined;
    xtsDecrypt(data_key, tweak_key, 0, &cipher, &plain);
    try std.testing.expectEqualSlices(u8, &expected, &plain);
}

test "rsa pkcs1 v1.5 decrypt recovers the pkg derived key 3 blob" {
    // Entry 0x10 key slot 3 of the base Terraria sample. Expected value comes from the
    // reference implementation; a wrong key or padding path fails here.
    const cipher_hex = "524cd216e2314f7debab237f412ad3c172eda52d1fde9b42fe64ac363a3e3e73e27fd8b5814aab350a63708b6744796bba089e49d426d82f7e52ee173d20aaa61d1a216aa9939b7131d700e42a2f36ab86a9b3b8438c65b02a39c06b09d0c823f4fe07400833fcb6b3ebad8e24b2847d6803ff5cec45ea4f019c4f3bc8b7a663da45cd7f73063fc5af5f710c5d7ff584ed66cd5d8c703a9d5fa259322f936a4d8c873037ef15025ede22defaa426653734b1e9eabcc585596b5c4d3313c1b9a57475912ccd2e4b9b9da4943684be241537137cd318fb76478bccb351ce5a06b4e5949507b2f5ae8128332e2f469b4f86dd4f00d8e46efcf6ca06a611e450194b";
    var cipher: [rsa_bytes]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cipher, cipher_hex);

    var out: [32]u8 = undefined;
    const msg = try rsaPkcs1v15Decrypt(pkg_key_set, &cipher, &out);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "9c807e006677e0e2ebc5aa9c14dede945a225c35a17ccda7137422b40de9a662");
    try std.testing.expectEqualSlices(u8, &expected, msg);
}

test "rsa pkcs1 v1.5 decrypt recovers ekpfs with the fake keyset" {
    const cipher_hex = "08564d1dc57eaf1ebb48c22a107aca1b2a0336996e01efe9f4bdfebc0763e83f1ded31c401ed5c53aeef9de184d259f444388cbeb72857fe2f5979973696f1614407c74f55ccf38dc97b1a9f5791ae26367625b8fdc2c722c152ea462535f1080e0f0f5b213ecf7ce3beaed08b19b43f07283a6bb8d16045b7dab63035f94a540f2c369a88e5f78daa1550214f37926ea5f54936638b01f30a25314880475b5148181b0b8de6913597584d4ce943b692e03e9d8d4e852ad768a46d3b2ed606a103b608440791a4556b44660817f24afab7f443969ddbc83337a292ec6b118886e1c6493f97788760f352afd9031e99b069234c80a815cc73f612f4a6607c0237";
    var cipher: [rsa_bytes]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cipher, cipher_hex);

    var out: [32]u8 = undefined;
    const msg = try rsaPkcs1v15Decrypt(fake_key_set, &cipher, &out);
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "6691a11375d495ef031d876a1a6ca5b5b00a5eb8644d68ef18e99231546369ab");
    try std.testing.expectEqualSlices(u8, &expected, msg);
}

test "rsa pkcs1 v1.5 decrypt rejects a short ciphertext" {
    var out: [32]u8 = undefined;
    const zeros: [16]u8 = @splat(0);
    try std.testing.expectError(error.CiphertextWrongLength, rsaPkcs1v15Decrypt(fake_key_set, &zeros, &out));
}

test "sha256 and hmac-sha256 match published vectors" {
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") catch unreachable;
    try std.testing.expectEqualSlices(u8, &digest, &sha256(""));

    // RFC 4231 test case 1.
    var key: [20]u8 = undefined;
    @memset(&key, 0x0b);
    var mac: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&mac, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7") catch unreachable;
    try std.testing.expectEqualSlices(u8, &mac, &hmacSha256(&key, "Hi There"));
}
