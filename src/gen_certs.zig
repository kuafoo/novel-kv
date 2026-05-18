// NovelKV - 自签名 TLS 证书生成
// 使用 Zig 标准库 ECDSA P-256 + DER 编码，零外部依赖
const std = @import("std");
const log = @import("log.zig");
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const der = std.crypto.codecs.asn1.der;
const Oid = std.crypto.codecs.asn1.Oid;

// X.509 相关 OID（编译期构造）
const oid_ecdsa_with_sha256 = Oid.fromDotComptime("1.2.840.10045.4.3.2");
const oid_ec_public_key = Oid.fromDotComptime("1.2.840.10045.2.1");
const oid_prime256v1 = Oid.fromDotComptime("1.2.840.10045.3.1.7");
const oid_common_name = Oid.fromDotComptime("2.5.4.3");

// DER tag 常量
const TAG_SEQUENCE: u8 = 0x30;
const TAG_SET: u8 = 0x31;
const TAG_INTEGER: u8 = 0x02;
const TAG_BIT_STRING: u8 = 0x03;
const TAG_OCTET_STRING: u8 = 0x04;
const TAG_OID: u8 = 0x06;
const TAG_UTF8STRING: u8 = 0x0C;
const TAG_PRINTABLE_STRING: u8 = 0x13;
const TAG_UTC_TIME: u8 = 0x17;
const TAG_GENERALIZED_TIME: u8 = 0x18;
const TAG_CONTEXT_0: u8 = 0xA0;
const TAG_CONTEXT_1: u8 = 0xA1;
const TAG_CONTEXT_3: u8 = 0xA3;

pub fn generateCert(io: std.Io, allocator: std.mem.Allocator, common_name: []const u8, days_valid: u32) !struct { cert_pem: []u8, key_pem: []u8 } {
    // 1. 生成 ECDSA P-256 密钥对
    const kp = Ecdsa.KeyPair.generate(io);
    const pub_sec1 = kp.public_key.toUncompressedSec1();
    const priv_bytes = Ecdsa.SecretKey.toBytes(kp.secret_key);

    // 2. 生成随机序列号
    var serial_bytes: [16]u8 = undefined;
    io.random(&serial_bytes);
    serial_bytes[0] &= 0x7F; // 确保正数

    // 3. 计算 validity 时间
    var now_ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &now_ts);
    const not_before = now_ts.sec;
    const not_after = not_before + @as(i64, days_valid) * 86400;

    // 4. 编码 SubjectPublicKeyInfo
    const spki = try encodeSubjectPublicKeyInfo(allocator, &pub_sec1);
    defer allocator.free(spki);

    // 5. 编码 AlgorithmIdentifier
    const sig_algo = try encodeEcdsaAlgorithmId(allocator);
    defer allocator.free(sig_algo);

    // 6. 编码 TBSCertificate
    const tbs = try encodeTBSCertificate(allocator, &serial_bytes, sig_algo, common_name, not_before, not_after, spki);
    defer allocator.free(tbs);

    // 7. 签名
    var signature = try kp.sign(tbs, null);
    var sig_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = signature.toDer(&sig_der_buf);

    // 8. 编码完整 Certificate
    const cert_der = try encodeCertificate(allocator, tbs, sig_algo, sig_der);
    defer allocator.free(cert_der);

    // 9. 转为 PEM
    const cert_pem = try derToPem(allocator, "CERTIFICATE", cert_der);
    errdefer allocator.free(cert_pem);

    // 10. 编码私钥 SEC1
    const key_der = try encodeECPrivateKey(allocator, &priv_bytes, &pub_sec1);
    defer allocator.free(key_der);

    const key_pem = try derToPem(allocator, "EC PRIVATE KEY", key_der);
    errdefer allocator.free(key_pem);

    return .{ .cert_pem = cert_pem, .key_pem = key_pem };
}

// === DER 编码辅助函数 ===

fn encodeLength(buf: []u8, len: usize) []const u8 {
    if (len < 128) {
        buf[0] = @intCast(len);
        return buf[0..1];
    } else if (len < 256) {
        buf[0] = 0x81;
        buf[1] = @intCast(len);
        return buf[0..2];
    } else {
        buf[0] = 0x82;
        buf[1] = @intCast(len >> 8);
        buf[2] = @intCast(len & 0xFF);
        return buf[0..3];
    }
}

fn wrapTag(allocator: std.mem.Allocator, tag: u8, content: []const u8) ![]u8 {
    var len_buf: [4]u8 = undefined;
    const len_enc = encodeLength(&len_buf, content.len);
    const total = 1 + len_enc.len + content.len;
    const result = try allocator.alloc(u8, total);
    result[0] = tag;
    @memcpy(result[1 .. 1 + len_enc.len], len_enc);
    @memcpy(result[1 + len_enc.len ..], content);
    return result;
}

fn concat(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    const result = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (parts) |p| {
        @memcpy(result[offset .. offset + p.len], p);
        offset += p.len;
    }
    return result;
}

fn encodeOidBytes(allocator: std.mem.Allocator, oid: Oid) ![]u8 {
    return wrapTag(allocator, TAG_OID, oid.encoded);
}

fn encodeInteger(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // 如果高位为 1，需要前导零
    if (bytes[0] & 0x80 != 0) {
        const padded = try allocator.alloc(u8, bytes.len + 1);
        padded[0] = 0;
        @memcpy(padded[1..], bytes);
        defer allocator.free(padded);
        return wrapTag(allocator, TAG_INTEGER, padded);
    }
    return wrapTag(allocator, TAG_INTEGER, bytes);
}

fn encodeSmallInteger(allocator: std.mem.Allocator, val: u64) ![]u8 {
    if (val == 0) {
        const zero = [_]u8{0};
        return wrapTag(allocator, TAG_INTEGER, &zero);
    }
    var buf: [9]u8 = undefined;
    var i: usize = 8;
    buf[8] = @intCast(val & 0xFF);
    var v = val >> 8;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast(v & 0xFF);
        v >>= 8;
    }
    return encodeInteger(allocator, buf[i..9]);
}

fn encodeString(allocator: std.mem.Allocator, tag: u8, str: []const u8) ![]u8 {
    return wrapTag(allocator, tag, str);
}

fn encodeTime(allocator: std.mem.Allocator, epoch_seconds: i64) ![]u8 {
    // 转为 UTC time: YYMMDDHHMMSSZ
    const days_since_epoch = @divFloor(epoch_seconds, 86400);
    const time_of_day = epoch_seconds - days_since_epoch * 86400;
    const hours = @divFloor(time_of_day, 3600);
    const minutes = @divFloor(time_of_day - hours * 3600, 60);
    const seconds = time_of_day - hours * 3600 - minutes * 60;

    // 简单的日期计算（从 1970-01-01）
    var y: i64 = 1970;
    var remaining_days = days_since_epoch;
    while (true) {
        const days_in_year: i64 = if (isLeapYear(@intCast(y))) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        y += 1;
    }
    const month_days = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: usize = 0;
    while (m < 12) {
        var dim = month_days[m];
        if (m == 1 and isLeapYear(@intCast(y))) dim += 1;
        if (remaining_days < dim) break;
        remaining_days -= dim;
        m += 1;
    }
    const d = remaining_days + 1;

    var buf: [64]u8 = undefined;
    const y_int: u32 = @intCast(y);
    const m_int: u32 = @intCast(m + 1);
    const d_int: u32 = @intCast(d);
    const h_int: u32 = @intCast(hours);
    const min_int: u32 = @intCast(minutes);
    const s_int: u32 = @intCast(seconds);
    const time_str = if (y >= 2050)
        std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{ y_int, m_int, d_int, h_int, min_int, s_int }) catch unreachable
    else
        std.fmt.bufPrint(&buf, "{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{ y_int % 100, m_int, d_int, h_int, min_int, s_int }) catch unreachable;

    const tag_type = if (y >= 2050) TAG_GENERALIZED_TIME else TAG_UTC_TIME;
    return encodeString(allocator, tag_type, time_str);
}

fn isLeapYear(y: i64) bool {
    return (@rem(y, 4) == 0 and @rem(y, 100) != 0) or @rem(y, 400) == 0;
}

// === X.509 结构编码 ===

fn encodeEcdsaAlgorithmId(allocator: std.mem.Allocator) ![]u8 {
    const oid_bytes = try encodeOidBytes(allocator, oid_ecdsa_with_sha256);
    defer allocator.free(oid_bytes);
    return wrapTag(allocator, TAG_SEQUENCE, oid_bytes);
}

fn encodeSubjectPublicKeyInfo(allocator: std.mem.Allocator, pub_key: *const [65]u8) ![]u8 {
    const ec_oid = try encodeOidBytes(allocator, oid_ec_public_key);
    defer allocator.free(ec_oid);
    const curve_oid = try encodeOidBytes(allocator, oid_prime256v1);
    defer allocator.free(curve_oid);
    const algo_content = try concat(allocator, &.{ ec_oid, curve_oid });
    defer allocator.free(algo_content);
    const algo_seq = try wrapTag(allocator, TAG_SEQUENCE, algo_content);
    defer allocator.free(algo_seq);

    // BIT STRING: 0x00 前缀 + 公钥
    const bit_content = try allocator.alloc(u8, 1 + pub_key.len);
    bit_content[0] = 0x00;
    @memcpy(bit_content[1..], pub_key);
    defer allocator.free(bit_content);
    const bit_string = try wrapTag(allocator, TAG_BIT_STRING, bit_content);
    defer allocator.free(bit_string);

    return wrapTag(allocator, TAG_SEQUENCE, try concat(allocator, &.{ algo_seq, bit_string }));
}

fn encodeName(allocator: std.mem.Allocator, common_name: []const u8) ![]u8 {
    const cn_oid = try encodeOidBytes(allocator, oid_common_name);
    defer allocator.free(cn_oid);
    const cn_str = try encodeString(allocator, TAG_UTF8STRING, common_name);
    defer allocator.free(cn_str);
    // SEQUENCE { OID, UTF8STRING }
    const cn_atv = try concat(allocator, &.{ cn_oid, cn_str });
    defer allocator.free(cn_atv);
    const cn_atv_seq = try wrapTag(allocator, TAG_SEQUENCE, cn_atv);
    defer allocator.free(cn_atv_seq);
    // SET { SEQUENCE }
    const cn_rdn = try wrapTag(allocator, TAG_SET, cn_atv_seq);
    defer allocator.free(cn_rdn);
    // SEQUENCE { SET } = Name
    return wrapTag(allocator, TAG_SEQUENCE, cn_rdn);
}

fn encodeValidity(allocator: std.mem.Allocator, not_before: i64, not_after: i64) ![]u8 {
    const nb = try encodeTime(allocator, not_before);
    defer allocator.free(nb);
    const na = try encodeTime(allocator, not_after);
    defer allocator.free(na);
    const content = try concat(allocator, &.{ nb, na });
    defer allocator.free(content);
    return wrapTag(allocator, TAG_SEQUENCE, content);
}

fn encodeTBSCertificate(allocator: std.mem.Allocator, serial: []const u8, sig_algo: []const u8, common_name: []const u8, not_before: i64, not_after: i64, spki: []const u8) ![]u8 {
    // version [0] EXPLICIT INTEGER v3(2)
    const version_int = try encodeSmallInteger(allocator, 2);
    defer allocator.free(version_int);
    const version = try wrapTag(allocator, TAG_CONTEXT_0, version_int);
    defer allocator.free(version);

    // serialNumber
    const serial_int = try encodeInteger(allocator, serial);
    defer allocator.free(serial_int);

    // issuer = subject (自签名)
    const issuer = try encodeName(allocator, common_name);
    defer allocator.free(issuer);
    const subject = try encodeName(allocator, common_name);
    defer allocator.free(subject);

    // validity
    const validity = try encodeValidity(allocator, not_before, not_after);
    defer allocator.free(validity);

    // 拼装 TBSCertificate
    const content = try concat(allocator, &.{
        version,       // [0] EXPLICIT INTEGER 2
        serial_int,    // INTEGER serial
        sig_algo,      // AlgorithmIdentifier
        issuer,        // Name
        validity,      // Validity
        subject,       // Name
        spki,          // SubjectPublicKeyInfo
    });
    defer allocator.free(content);
    return wrapTag(allocator, TAG_SEQUENCE, content);
}

fn encodeCertificate(allocator: std.mem.Allocator, tbs: []const u8, sig_algo: []const u8, sig_der: []const u8) ![]u8 {
    // signatureValue BIT STRING
    const sig_with_prefix = try allocator.alloc(u8, 1 + sig_der.len);
    sig_with_prefix[0] = 0x00;
    @memcpy(sig_with_prefix[1..], sig_der);
    defer allocator.free(sig_with_prefix);
    const sig_bit_string = try wrapTag(allocator, TAG_BIT_STRING, sig_with_prefix);
    defer allocator.free(sig_bit_string);

    const content = try concat(allocator, &.{ tbs, sig_algo, sig_bit_string });
    defer allocator.free(content);
    return wrapTag(allocator, TAG_SEQUENCE, content);
}

fn encodeECPrivateKey(allocator: std.mem.Allocator, priv_bytes: *const [32]u8, pub_key: *const [65]u8) ![]u8 {
    // version INTEGER 1
    const version = try encodeSmallInteger(allocator, 1);
    defer allocator.free(version);

    // privateKey OCTET STRING
    const priv_octet = try wrapTag(allocator, TAG_OCTET_STRING, priv_bytes);
    defer allocator.free(priv_octet);

    // parameters [0] OID prime256v1
    const curve_oid = try encodeOidBytes(allocator, oid_prime256v1);
    defer allocator.free(curve_oid);
    const parameters = try wrapTag(allocator, TAG_CONTEXT_0, curve_oid);
    defer allocator.free(parameters);

    // publicKey [1] BIT STRING
    const pub_with_prefix = try allocator.alloc(u8, 1 + pub_key.len);
    pub_with_prefix[0] = 0x00;
    @memcpy(pub_with_prefix[1..], pub_key);
    defer allocator.free(pub_with_prefix);
    const pub_bit = try wrapTag(allocator, TAG_BIT_STRING, pub_with_prefix);
    defer allocator.free(pub_bit);
    const public_key_field = try wrapTag(allocator, TAG_CONTEXT_1, pub_bit);
    defer allocator.free(public_key_field);

    const content = try concat(allocator, &.{ version, priv_octet, parameters, public_key_field });
    defer allocator.free(content);
    return wrapTag(allocator, TAG_SEQUENCE, content);
}

// === PEM 编码 ===

fn derToPem(allocator: std.mem.Allocator, label: []const u8, der_bytes: []const u8) ![]u8 {
    const b64_len = std.base64.standard.Encoder.calcSize(der_bytes.len);
    // 估算 PEM 总长度
    const header = "-----BEGIN -----";
    const footer = "-----END -----";
    const line_width = 64;
    const b64_lines = (b64_len + line_width - 1) / line_width;
    const total = header.len + label.len * 2 + b64_len + b64_lines + footer.len + 4;

    const result = try allocator.alloc(u8, total);
    var fbs = std.Io.Writer.fixed(result);
    const w = &fbs;

    w.writeAll("-----BEGIN ") catch unreachable;
    w.writeAll(label) catch unreachable;
    w.writeAll("-----\n") catch unreachable;

    var b64_buf: [4096]u8 = undefined;
    const b64_str = std.base64.standard.Encoder.encode(&b64_buf, der_bytes);

    var offset: usize = 0;
    while (offset < b64_str.len) {
        const end = @min(offset + line_width, b64_str.len);
        w.writeAll(b64_str[offset..end]) catch unreachable;
        w.writeAll("\n") catch unreachable;
        offset = end;
    }

    w.writeAll("-----END ") catch unreachable;
    w.writeAll(label) catch unreachable;
    w.writeAll("-----\n") catch unreachable;

    return result[0..fbs.end];
}
