package main

import (
	"bytes"
	"context"
	"fmt"
	"math"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

var ctx = context.Background()

type TestResult struct {
	name string
	pass bool
	err  string
}

func test(name string, fn func() error) TestResult {
	err := fn()
	if err != nil {
		return TestResult{name: name, pass: false, err: err.Error()}
	}
	return TestResult{name: name, pass: true}
}

func check(name string, fn func() (interface{}, error), expected interface{}) TestResult {
	result, err := fn()
	if err != nil {
		return TestResult{name: name, pass: false, err: err.Error()}
	}
	if result != expected {
		return TestResult{name: name, pass: false, err: fmt.Sprintf("expected %v, got %v", expected, result)}
	}
	return TestResult{name: name, pass: true}
}

// rawSend sends a raw RESP command and reads the response
func rawSend(cmd string) (string, error) {
	conn, err := net.DialTimeout("tcp", "localhost:6379", 5*time.Second)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	_, err = conn.Write([]byte(cmd))
	if err != nil {
		return "", err
	}
	buf := make([]byte, 65536)
	n, err := conn.Read(buf)
	if err != nil {
		return "", err
	}
	return string(buf[:n]), nil
}

func main() {
	rdb := redis.NewClient(&redis.Options{
		Addr: "localhost:6379",
	})
	defer rdb.Close()

	// Verify connection
	if err := rdb.Ping(ctx).Err(); err != nil {
		fmt.Printf("Cannot connect to NovelKV: %v\n", err)
		os.Exit(1)
	}

	var results []TestResult
	var cleanupKeys []string
	defer func() {
		if len(cleanupKeys) > 0 {
			rdb.Del(ctx, cleanupKeys...)
		}
	}()

	// ============================================================
	// 1. BASIC OPERATIONS
	// ============================================================
	results = append(results, test("PING", func() error {
		return rdb.Ping(ctx).Err()
	}))

	results = append(results, check("SET/GET basic", func() (interface{}, error) {
		cleanupKeys = append(cleanupKeys, "t:basic")
		return rdb.Set(ctx, "t:basic", "hello", 0).Result()
	}, "OK"))
	results = append(results, check("GET basic", func() (interface{}, error) {
		return rdb.Get(ctx, "t:basic").Result()
	}, "hello"))

	results = append(results, test("GET nonexistent returns nil", func() error {
		val, err := rdb.Get(ctx, "t:nonexistent_xyz").Result()
		if err == redis.Nil {
			return nil
		}
		if err != nil {
			return err
		}
		return fmt.Errorf("expected nil, got %q", val)
	}))

	// DEL
	results = append(results, test("DEL existing key", func() error {
		rdb.Set(ctx, "t:del1", "val", 0)
		cleanupKeys = append(cleanupKeys, "t:del1")
		n, err := rdb.Del(ctx, "t:del1").Result()
		if err != nil {
			return err
		}
		if n != 1 {
			return fmt.Errorf("expected DEL=1, got %d", n)
		}
		return nil
	}))

	results = append(results, test("DEL nonexistent key returns 0", func() error {
		n, err := rdb.Del(ctx, "t:nonexistent_del").Result()
		if err != nil {
			return err
		}
		if n != 0 {
			return fmt.Errorf("expected DEL=0, got %d", n)
		}
		return nil
	}))

	results = append(results, test("DEL multiple keys", func() error {
		rdb.Set(ctx, "t:del2", "a", 0)
		rdb.Set(ctx, "t:del3", "b", 0)
		cleanupKeys = append(cleanupKeys, "t:del2", "t:del3")
		n, err := rdb.Del(ctx, "t:del2", "t:del3", "t:nonexistent_xyz").Result()
		if err != nil {
			return err
		}
		if n != 2 {
			return fmt.Errorf("expected DEL=2, got %d", n)
		}
		return nil
	}))

	// EXISTS
	results = append(results, test("EXISTS existing", func() error {
		rdb.Set(ctx, "t:exists1", "val", 0)
		cleanupKeys = append(cleanupKeys, "t:exists1")
		n, err := rdb.Exists(ctx, "t:exists1").Result()
		if err != nil {
			return err
		}
		if n != 1 {
			return fmt.Errorf("expected EXISTS=1, got %d", n)
		}
		return nil
	}))

	results = append(results, test("EXISTS nonexistent returns 0", func() error {
		n, err := rdb.Exists(ctx, "t:nonexistent_exists").Result()
		if err != nil {
			return err
		}
		if n != 0 {
			return fmt.Errorf("expected EXISTS=0, got %d", n)
		}
		return nil
	}))

	// MSET/MGET
	results = append(results, test("MSET/MGET basic", func() error {
		cleanupKeys = append(cleanupKeys, "t:m1", "t:m2", "t:m3")
		_, err := rdb.MSet(ctx, "t:m1", "a", "t:m2", "b", "t:m3", "c").Result()
		if err != nil {
			return err
		}
		vals, err := rdb.MGet(ctx, "t:m1", "t:m2", "t:m3").Result()
		if err != nil {
			return err
		}
		if len(vals) != 3 || vals[0] != "a" || vals[1] != "b" || vals[2] != "c" {
			return fmt.Errorf("unexpected MGET result: %v", vals)
		}
		return nil
	}))

	results = append(results, test("MGET with missing key returns nil", func() error {
		vals, err := rdb.MGet(ctx, "t:m1", "t:missing_m", "t:m3").Result()
		if err != nil {
			return err
		}
		if len(vals) != 3 || vals[0] != "a" || vals[1] != nil || vals[2] != "c" {
			return fmt.Errorf("unexpected MGET result: %v", vals)
		}
		return nil
	}))

	// SETNX
	results = append(results, test("SETNX new key", func() error {
		cleanupKeys = append(cleanupKeys, "t:setnx1")
		ok, err := rdb.SetNX(ctx, "t:setnx1", "val1", 0).Result()
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("expected SETNX=true for new key")
		}
		return nil
	}))

	results = append(results, test("SETNX existing key returns false", func() error {
		ok, err := rdb.SetNX(ctx, "t:setnx1", "val2", 0).Result()
		if err != nil {
			return err
		}
		if ok {
			return fmt.Errorf("expected SETNX=false for existing key")
		}
		val, _ := rdb.Get(ctx, "t:setnx1").Result()
		if val != "val1" {
			return fmt.Errorf("value should not change, got %q", val)
		}
		return nil
	}))

	// SET NX/XX options
	results = append(results, test("SET NX option", func() error {
		cleanupKeys = append(cleanupKeys, "t:setnxopt")
		ok, err := rdb.SetNX(ctx, "t:setnxopt", "nxval", 0).Result()
		if err != nil || !ok {
			return fmt.Errorf("SET NX new key failed: %v", err)
		}
		// SET NX on existing should return nil
		resp, err := rawSend("*4\r\n$3\r\nSET\r\n$9\r\nt:setnxopt\r\n$5\r\nnxval2\r\n$2\r\nNX\r\n")
		if err != nil {
			return err
		}
		if resp != "$-1\r\n" {
			return fmt.Errorf("expected $-1 for SET NX on existing, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("SET XX option - only set if exists", func() error {
		cleanupKeys = append(cleanupKeys, "t:setxx")
		// SET XX on nonexistent should return nil
		resp, err := rawSend("*4\r\n$3\r\nSET\r\n$7\r\nt:setxx\r\n$5\r\nxxval\r\n$2\r\nXX\r\n")
		if err != nil {
			return err
		}
		if resp != "$-1\r\n" {
			return fmt.Errorf("expected $-1 for SET XX on nonexistent, got %q", resp)
		}
		// Create key, then SET XX should succeed
		rdb.Set(ctx, "t:setxx", "old", 0)
		err = rdb.SetXX(ctx, "t:setxx", "new", 0).Err()
		if err != nil {
			return fmt.Errorf("SET XX on existing failed: %v", err)
		}
		val, _ := rdb.Get(ctx, "t:setxx").Result()
		if val != "new" {
			return fmt.Errorf("expected 'new', got %q", val)
		}
		return nil
	}))

	// GETSET
	results = append(results, test("GETSET returns old value", func() error {
		cleanupKeys = append(cleanupKeys, "t:getset")
		rdb.Set(ctx, "t:getset", "old", 0)
		old, err := rdb.GetSet(ctx, "t:getset", "new").Result()
		if err != nil {
			return err
		}
		if old != "old" {
			return fmt.Errorf("expected 'old', got %q", old)
		}
		val, _ := rdb.Get(ctx, "t:getset").Result()
		if val != "new" {
			return fmt.Errorf("expected 'new' after GETSET, got %q", val)
		}
		return nil
	}))

	results = append(results, test("GETSET on nonexistent returns nil", func() error {
		cleanupKeys = append(cleanupKeys, "t:getset2")
		val, err := rdb.GetSet(ctx, "t:getset2", "val").Result()
		if err != redis.Nil {
			return fmt.Errorf("expected nil, got val=%q err=%v", val, err)
		}
		return nil
	}))

	// APPEND
	results = append(results, test("APPEND to new key", func() error {
		cleanupKeys = append(cleanupKeys, "t:append1")
		n, err := rdb.Append(ctx, "t:append1", "hello").Result()
		if err != nil || n != 5 {
			return fmt.Errorf("expected length 5, got %d, err=%v", n, err)
		}
		return nil
	}))

	results = append(results, test("APPEND to existing key", func() error {
		n, err := rdb.Append(ctx, "t:append1", " world").Result()
		if err != nil || n != 11 {
			return fmt.Errorf("expected length 11, got %d, err=%v", n, err)
		}
		val, _ := rdb.Get(ctx, "t:append1").Result()
		if val != "hello world" {
			return fmt.Errorf("expected 'hello world', got %q", val)
		}
		return nil
	}))

	// STRLEN
	results = append(results, check("STRLEN", func() (interface{}, error) {
		rdb.Set(ctx, "t:strlen", "hello", 0)
		cleanupKeys = append(cleanupKeys, "t:strlen")
		return rdb.StrLen(ctx, "t:strlen").Result()
	}, int64(5)))

	results = append(results, check("STRLEN nonexistent", func() (interface{}, error) {
		return rdb.StrLen(ctx, "t:nonexistent_strlen").Result()
	}, int64(0)))

	// ECHO
	results = append(results, check("ECHO", func() (interface{}, error) {
		return rdb.Echo(ctx, "test message").Result()
	}, "test message"))

	// ============================================================
	// 2. NUMERIC OPERATIONS
	// ============================================================
	results = append(results, test("INCR from nil", func() error {
		cleanupKeys = append(cleanupKeys, "t:incr1")
		rdb.Del(ctx, "t:incr1")
		n, err := rdb.Incr(ctx, "t:incr1").Result()
		if err != nil || n != 1 {
			return fmt.Errorf("expected 1, got %d", n)
		}
		return nil
	}))

	results = append(results, test("INCRBY positive", func() error {
		n, err := rdb.IncrBy(ctx, "t:incr1", 100).Result()
		if err != nil || n != 101 {
			return fmt.Errorf("expected 101, got %d", n)
		}
		return nil
	}))

	results = append(results, test("DECR", func() error {
		n, err := rdb.Decr(ctx, "t:incr1").Result()
		if err != nil || n != 100 {
			return fmt.Errorf("expected 100, got %d", n)
		}
		return nil
	}))

	results = append(results, test("DECRBY", func() error {
		n, err := rdb.DecrBy(ctx, "t:incr1", 50).Result()
		if err != nil || n != 50 {
			return fmt.Errorf("expected 50, got %d", n)
		}
		return nil
	}))

	results = append(results, test("INCR on non-integer value returns error", func() error {
		cleanupKeys = append(cleanupKeys, "t:incrstr")
		rdb.Set(ctx, "t:incrstr", "notanumber", 0)
		_, err := rdb.Incr(ctx, "t:incrstr").Result()
		if err == nil {
			return fmt.Errorf("expected error for INCR on non-integer")
		}
		return nil
	}))

	results = append(results, test("INCR overflow protection", func() error {
		cleanupKeys = append(cleanupKeys, "t:incrover")
		rdb.Set(ctx, "t:incrover", strconv.FormatInt(math.MaxInt64, 10), 0)
		_, err := rdb.Incr(ctx, "t:incrover").Result()
		if err == nil {
			return fmt.Errorf("expected error for INCR overflow")
		}
		return nil
	}))

	results = append(results, test("DECR underflow protection", func() error {
		cleanupKeys = append(cleanupKeys, "t:decrunder")
		rdb.Set(ctx, "t:decrunder", strconv.FormatInt(math.MinInt64, 10), 0)
		_, err := rdb.Decr(ctx, "t:decrunder").Result()
		if err == nil {
			return fmt.Errorf("expected error for DECR underflow")
		}
		return nil
	}))

	results = append(results, test("INCR negative delta", func() error {
		cleanupKeys = append(cleanupKeys, "t:incrneg")
		rdb.Set(ctx, "t:incrneg", "10", 0)
		n, err := rdb.IncrBy(ctx, "t:incrneg", -3).Result()
		if err != nil || n != 7 {
			return fmt.Errorf("expected 7, got %d", n)
		}
		return nil
	}))

	// ============================================================
	// 3. GETRANGE / SETRANGE
	// ============================================================
	results = append(results, test("GETRANGE basic", func() error {
		cleanupKeys = append(cleanupKeys, "t:range1")
		rdb.Set(ctx, "t:range1", "hello world", 0)
		val, err := rdb.GetRange(ctx, "t:range1", 0, 4).Result()
		if err != nil || val != "hello" {
			return fmt.Errorf("expected 'hello', got %q", val)
		}
		return nil
	}))

	results = append(results, test("GETRANGE negative indices", func() error {
		val, err := rdb.GetRange(ctx, "t:range1", -5, -1).Result()
		if err != nil || val != "world" {
			return fmt.Errorf("expected 'world', got %q", val)
		}
		return nil
	}))

	results = append(results, test("GETRANGE out of bounds", func() error {
		val, err := rdb.GetRange(ctx, "t:range1", 0, 100).Result()
		if err != nil || val != "hello world" {
			return fmt.Errorf("expected 'hello world', got %q", val)
		}
		return nil
	}))

	results = append(results, test("SETRANGE basic", func() error {
		cleanupKeys = append(cleanupKeys, "t:range2")
		rdb.Set(ctx, "t:range2", "hello world", 0)
		n, err := rdb.SetRange(ctx, "t:range2", 6, "Redis").Result()
		if err != nil || n != 11 {
			return fmt.Errorf("expected 11, got %d", n)
		}
		val, _ := rdb.Get(ctx, "t:range2").Result()
		if val != "hello Redis" {
			return fmt.Errorf("expected 'hello Redis', got %q", val)
		}
		return nil
	}))

	results = append(results, test("SETRANGE beyond end (zero-fill)", func() error {
		cleanupKeys = append(cleanupKeys, "t:range3")
		rdb.Set(ctx, "t:range3", "hi", 0)
		n, err := rdb.SetRange(ctx, "t:range3", 5, "X").Result()
		if err != nil || n != 6 {
			return fmt.Errorf("expected 6, got %d", n)
		}
		val, _ := rdb.Get(ctx, "t:range3").Result()
		expected := "hi\x00\x00\x00X"
		if val != expected {
			return fmt.Errorf("expected %q, got %q", expected, val)
		}
		return nil
	}))

	// ============================================================
	// 4. BINARY SAFETY
	// ============================================================
	results = append(results, test("Binary value with null bytes", func() error {
		cleanupKeys = append(cleanupKeys, "t:bin1")
		binaryVal := []byte{0x00, 0x01, 0x02, 0x00, 0xFF, 0xFE}
		err := rdb.Set(ctx, "t:bin1", binaryVal, 0).Err()
		if err != nil {
			return err
		}
		got, err := rdb.Get(ctx, "t:bin1").Bytes()
		if err != nil {
			return err
		}
		if !bytes.Equal(got, binaryVal) {
			return fmt.Errorf("binary mismatch: expected %v, got %v", binaryVal, got)
		}
		return nil
	}))

	results = append(results, test("Binary key with special bytes", func() error {
		key := "t:bin\x00key"
		cleanupKeys = append(cleanupKeys, "t:bin\x01key") // cleanup what we can
		err := rdb.Set(ctx, key, "binary_key_val", 0).Err()
		if err != nil {
			return err
		}
		val, err := rdb.Get(ctx, key).Result()
		if err != nil {
			return err
		}
		if val != "binary_key_val" {
			return fmt.Errorf("expected 'binary_key_val', got %q", val)
		}
		rdb.Del(ctx, key)
		return nil
	}))

	results = append(results, test("Empty value", func() error {
		cleanupKeys = append(cleanupKeys, "t:empty")
		err := rdb.Set(ctx, "t:empty", "", 0).Err()
		if err != nil {
			return err
		}
		val, err := rdb.Get(ctx, "t:empty").Result()
		if err != nil {
			return err
		}
		if val != "" {
			return fmt.Errorf("expected empty string, got %q", val)
		}
		return nil
	}))

	results = append(results, test("Key with spaces", func() error {
		cleanupKeys = append(cleanupKeys, "t:key with spaces")
		err := rdb.Set(ctx, "t:key with spaces", "val", 0).Err()
		if err != nil {
			return err
		}
		val, err := rdb.Get(ctx, "t:key with spaces").Result()
		if err != nil || val != "val" {
			return fmt.Errorf("expected 'val', got %q, err=%v", val, err)
		}
		return nil
	}))

	results = append(results, test("Key with unicode/CJK", func() error {
		key := "t:中文键"
		cleanupKeys = append(cleanupKeys, key)
		err := rdb.Set(ctx, key, "中文值", 0).Err()
		if err != nil {
			return err
		}
		val, err := rdb.Get(ctx, key).Result()
		if err != nil || val != "中文值" {
			return fmt.Errorf("expected '中文值', got %q, err=%v", val, err)
		}
		return nil
	}))

	results = append(results, test("Value with newlines", func() error {
		cleanupKeys = append(cleanupKeys, "t:newline")
		val := "line1\nline2\r\nline3"
		err := rdb.Set(ctx, "t:newline", val, 0).Err()
		if err != nil {
			return err
		}
		got, err := rdb.Get(ctx, "t:newline").Result()
		if err != nil || got != val {
			return fmt.Errorf("newline value mismatch: expected %q, got %q", val, got)
		}
		return nil
	}))

	results = append(results, test("Value with emoji", func() error {
		cleanupKeys = append(cleanupKeys, "t:emoji")
		val := "Hello 🌍 World 🎉"
		err := rdb.Set(ctx, "t:emoji", val, 0).Err()
		if err != nil {
			return err
		}
		got, err := rdb.Get(ctx, "t:emoji").Result()
		if err != nil || got != val {
			return fmt.Errorf("emoji mismatch: expected %q, got %q", val, got)
		}
		return nil
	}))

	// ============================================================
	// 5. LARGE VALUES
	// ============================================================
	results = append(results, test("16KB value", func() error {
		cleanupKeys = append(cleanupKeys, "t:large16k")
		largeVal := string(bytes.Repeat([]byte("A"), 16*1024))
		err := rdb.Set(ctx, "t:large16k", largeVal, 0).Err()
		if err != nil {
			return fmt.Errorf("SET 16KB failed: %v", err)
		}
		got, err := rdb.Get(ctx, "t:large16k").Result()
		if err != nil {
			return fmt.Errorf("GET 16KB failed: %v", err)
		}
		if len(got) != 16*1024 {
			return fmt.Errorf("expected 16384 bytes, got %d", len(got))
		}
		return nil
	}))

	results = append(results, test("64KB value", func() error {
		cleanupKeys = append(cleanupKeys, "t:large64k")
		largeVal := string(bytes.Repeat([]byte("B"), 64*1024))
		err := rdb.Set(ctx, "t:large64k", largeVal, 0).Err()
		if err != nil {
			return fmt.Errorf("SET 64KB failed: %v", err)
		}
		got, err := rdb.Get(ctx, "t:large64k").Result()
		if err != nil {
			return fmt.Errorf("GET 64KB failed: %v", err)
		}
		if len(got) != 64*1024 {
			return fmt.Errorf("expected 65536 bytes, got %d", len(got))
		}
		return nil
	}))

	results = append(results, test("1MB value", func() error {
		cleanupKeys = append(cleanupKeys, "t:large1m")
		largeVal := string(bytes.Repeat([]byte("C"), 1024*1024))
		err := rdb.Set(ctx, "t:large1m", largeVal, 0).Err()
		if err != nil {
			return fmt.Errorf("SET 1MB failed: %v", err)
		}
		got, err := rdb.Get(ctx, "t:large1m").Result()
		if err != nil {
			return fmt.Errorf("GET 1MB failed: %v", err)
		}
		if len(got) != 1024*1024 {
			return fmt.Errorf("expected 1048576 bytes, got %d", len(got))
		}
		return nil
	}))

	// ============================================================
	// 6. PROTOCOL COMPATIBILITY
	// ============================================================
	results = append(results, test("Inline PING via raw RESP", func() error {
		resp, err := rawSend("PING\r\n")
		if err != nil {
			return err
		}
		if resp != "+PONG\r\n" {
			return fmt.Errorf("expected +PONG, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("Inline PING with message", func() error {
		resp, err := rawSend("PING hello\r\n")
		if err != nil {
			return err
		}
		if resp != "+hello\r\n" {
			return fmt.Errorf("expected +hello, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("Array format GET/SET", func() error {
		cleanupKeys = append(cleanupKeys, "t:prototest")
		resp, err := rawSend("*3\r\n$3\r\nSET\r\n$10\r\nt:prototest\r\n$3\r\nabc\r\n")
		if err != nil {
			return err
		}
		if resp != "+OK\r\n" {
			return fmt.Errorf("expected +OK, got %q", resp)
		}
		resp, err = rawSend("*2\r\n$3\r\nGET\r\n$10\r\nt:prototest\r\n")
		if err != nil {
			return err
		}
		if resp != "$3\r\nabc\r\n" {
			return fmt.Errorf("expected $3\\r\\nabc\\r\\n, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("GET returns null bulk string for missing key", func() error {
		resp, err := rawSend("*2\r\n$3\r\nGET\r\n$20\r\nt:missing_protokey\r\n")
		if err != nil {
			return err
		}
		if resp != "$-1\r\n" {
			return fmt.Errorf("expected $-1\\r\\n, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("DEL returns integer", func() error {
		cleanupKeys = append(cleanupKeys, "t:delint")
		rdb.Set(ctx, "t:delint", "val", 0)
		resp, err := rawSend("*2\r\n$3\r\nDEL\r\n$8\r\nt:delint\r\n")
		if err != nil {
			return err
		}
		if resp != ":1\r\n" {
			return fmt.Errorf("expected :1\\r\\n, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("INCR returns integer", func() error {
		cleanupKeys = append(cleanupKeys, "t:incrint")
		rdb.Del(ctx, "t:incrint")
		resp, err := rawSend("*2\r\n$4\r\nINCR\r\n$9\r\nt:incrint\r\n")
		if err != nil {
			return err
		}
		if resp != ":1\r\n" {
			return fmt.Errorf("expected :1\\r\\n, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("EXISTS returns integer", func() error {
		cleanupKeys = append(cleanupKeys, "t:existsint")
		rdb.Set(ctx, "t:existsint", "val", 0)
		resp, err := rawSend("*2\r\n$6\r\nEXISTS\r\n$10\r\nt:existsint\r\n")
		if err != nil {
			return err
		}
		if resp != ":1\r\n" {
			return fmt.Errorf("expected :1\\r\\n, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("Unknown command returns error", func() error {
		resp, err := rawSend("*1\r\n$7\r\nUNKNOWN\r\n")
		if err != nil {
			return err
		}
		if len(resp) == 0 || resp[0] != '-' {
			return fmt.Errorf("expected error response, got %q", resp)
		}
		return nil
	}))

	results = append(results, test("Command case insensitivity", func() error {
		cleanupKeys = append(cleanupKeys, "t:case")
		rdb.Set(ctx, "t:case", "val", 0)
		// Test uppercase SET via raw protocol
		resp, err := rawSend("*3\r\n$3\r\nSET\r\n$6\r\nt:case\r\n$3\r\nVAV\r\n")
		if err != nil {
			return err
		}
		if resp != "+OK\r\n" {
			return fmt.Errorf("expected +OK for uppercase SET, got %q", resp)
		}
		// Test mixed case GET
		resp, err = rawSend("*2\r\n$3\r\nget\r\n$6\r\nt:case\r\n")
		if err != nil {
			return err
		}
		if resp != "$3\r\nVAV\r\n" {
			return fmt.Errorf("expected $3\\r\\nVAV\\r\\n for lowercase get, got %q", resp)
		}
		return nil
	}))

	// ============================================================
	// 7. CONCURRENT ACCESS
	// ============================================================
	results = append(results, test("Concurrent reads/writes", func() error {
		const numGoroutines = 10
		const numOps = 100
		cleanupKeys = append(cleanupKeys, "t:conc:key")

		var wg sync.WaitGroup
		errCh := make(chan error, numGoroutines)

		// Pre-populate
		rdb.Set(ctx, "t:conc:key", "0", 0)

		// Concurrent incrementers
		for g := 0; g < numGoroutines; g++ {
			wg.Add(1)
			go func(id int) {
				defer wg.Done()
				localRdb := redis.NewClient(&redis.Options{Addr: "localhost:6379"})
				defer localRdb.Close()
				for i := 0; i < numOps; i++ {
					key := fmt.Sprintf("t:conc:g%d:i%d", id, i)
					err := localRdb.Set(ctx, key, fmt.Sprintf("val_%d_%d", id, i), 0).Err()
					if err != nil {
						errCh <- fmt.Errorf("goroutine %d SET failed: %v", id, err)
						return
					}
				}
			}(g)
		}

		wg.Wait()
		close(errCh)
		for err := range errCh {
			if err != nil {
				return err
			}
		}

		// Verify all keys exist
		for g := 0; g < numGoroutines; g++ {
			key := fmt.Sprintf("t:conc:g%d:i%d", g, numOps-1)
			val, err := rdb.Get(ctx, key).Result()
			if err != nil {
				return fmt.Errorf("concurrent key %s missing: %v", key, err)
			}
			cleanupKeys = append(cleanupKeys, key)
			expected := fmt.Sprintf("val_%d_%d", g, numOps-1)
			if val != expected {
				return fmt.Errorf("concurrent key %s: expected %q, got %q", key, expected, val)
			}
		}

		// Clean up all concurrent keys
		for g := 0; g < numGoroutines; g++ {
			for i := 0; i < numOps; i++ {
				rdb.Del(ctx, fmt.Sprintf("t:conc:g%d:i%d", g, i))
			}
		}
		return nil
	}))

	results = append(results, test("Concurrent INCR on same key", func() error {
		cleanupKeys = append(cleanupKeys, "t:concincr")
		rdb.Set(ctx, "t:concincr", "0", 0)

		const numGoroutines = 10
		const numOps = 100
		var wg sync.WaitGroup
		errCh := make(chan error, numGoroutines)

		for g := 0; g < numGoroutines; g++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				localRdb := redis.NewClient(&redis.Options{Addr: "localhost:6379"})
				defer localRdb.Close()
				for i := 0; i < numOps; i++ {
					err := localRdb.Incr(ctx, "t:concincr").Err()
					if err != nil {
						errCh <- err
						return
					}
				}
			}()
		}

		wg.Wait()
		close(errCh)
		for err := range errCh {
			if err != nil {
				return err
			}
		}

		val, err := rdb.Get(ctx, "t:concincr").Int64()
		if err != nil {
			return err
		}
		expected := int64(numGoroutines * numOps)
		if val != expected {
			return fmt.Errorf("expected %d after concurrent INCR, got %d", expected, val)
		}
		return nil
	}))

	// ============================================================
	// 8. OVERWRITE & IDEMPOTENCY
	// ============================================================
	results = append(results, test("SET overwrites existing value", func() error {
		cleanupKeys = append(cleanupKeys, "t:overwrite")
		rdb.Set(ctx, "t:overwrite", "old", 0)
		rdb.Set(ctx, "t:overwrite", "new", 0)
		val, err := rdb.Get(ctx, "t:overwrite").Result()
		if err != nil || val != "new" {
			return fmt.Errorf("expected 'new', got %q", val)
		}
		return nil
	}))

	results = append(results, test("DEL is idempotent", func() error {
		cleanupKeys = append(cleanupKeys, "t:idemdel")
		rdb.Set(ctx, "t:idemdel", "val", 0)
		rdb.Del(ctx, "t:idemdel")
		rdb.Del(ctx, "t:idemdel") // second DEL should not error
		return nil
	}))

	// ============================================================
	// RESULTS
	// ============================================================
	passed := 0
	failed := 0
	for _, r := range results {
		if r.pass {
			passed++
			fmt.Printf("  PASS: %s\n", r.name)
		} else {
			failed++
			fmt.Printf("  FAIL: %s -> %s\n", r.name, r.err)
		}
	}
	fmt.Printf("\n=== Results: %d passed, %d failed ===\n", passed, failed)
	if failed > 0 {
		os.Exit(1)
	}
}
