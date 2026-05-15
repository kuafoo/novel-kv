package main

import (
	"context"
	"fmt"
	"os"

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

func main() {
	rdb := redis.NewClient(&redis.Options{
		Addr: "localhost:6379",
	})
	defer rdb.Close()

	var results []TestResult

	// PING
	results = append(results, test("PING", func() error {
		return rdb.Ping(ctx).Err()
	}))

	// SET/GET
	results = append(results, check("SET foo bar", func() (interface{}, error) {
		return rdb.Set(ctx, "foo", "bar", 0).Result()
	}, "OK"))
	results = append(results, check("GET foo", func() (interface{}, error) {
		return rdb.Get(ctx, "foo").Result()
	}, "bar"))
	results = append(results, check("GET nonexistent", func() (interface{}, error) {
		val, err := rdb.Get(ctx, "nonexistent_key_xyz").Result()
		if err == redis.Nil {
			return nil, nil
		}
		return val, err
	}, nil))

	// DEL
	rdb.Set(ctx, "del_test", "hello", 0)
	results = append(results, check("DEL del_test", func() (interface{}, error) {
		return rdb.Del(ctx, "del_test").Result()
	}, int64(1)))
	results = append(results, check("GET after DEL", func() (interface{}, error) {
		val, err := rdb.Get(ctx, "del_test").Result()
		if err == redis.Nil {
			return nil, nil
		}
		return val, err
	}, nil))

	// EXISTS
	rdb.Set(ctx, "exists_test", "hello", 0)
	results = append(results, check("EXISTS existing", func() (interface{}, error) {
		return rdb.Exists(ctx, "exists_test").Result()
	}, int64(1)))
	results = append(results, check("EXISTS nonexistent", func() (interface{}, error) {
		return rdb.Exists(ctx, "nonexistent_key_xyz2").Result()
	}, int64(0)))

	// MGET
	rdb.Set(ctx, "m1", "a", 0)
	rdb.Set(ctx, "m2", "b", 0)
	rdb.Set(ctx, "m3", "c", 0)
	results = append(results, test("MGET m1 m2 m3", func() error {
		vals, err := rdb.MGet(ctx, "m1", "m2", "m3").Result()
		if err != nil {
			return err
		}
		if len(vals) != 3 || vals[0] != "a" || vals[1] != "b" || vals[2] != "c" {
			return fmt.Errorf("unexpected MGET result: %v", vals)
		}
		return nil
	}))

	// MSET
	results = append(results, check("MSET", func() (interface{}, error) {
		return rdb.MSet(ctx, "ms1", "va", "ms2", "vb").Result()
	}, "OK"))
	results = append(results, check("GET ms1", func() (interface{}, error) {
		return rdb.Get(ctx, "ms1").Result()
	}, "va"))

	// INCR/DECR
	rdb.Del(ctx, "counter")
	results = append(results, check("INCR from nil", func() (interface{}, error) {
		return rdb.Incr(ctx, "counter").Result()
	}, int64(1)))
	results = append(results, check("INCRBY 5", func() (interface{}, error) {
		return rdb.IncrBy(ctx, "counter", 5).Result()
	}, int64(6)))
	results = append(results, check("DECR", func() (interface{}, error) {
		return rdb.Decr(ctx, "counter").Result()
	}, int64(5)))

	// APPEND
	rdb.Del(ctx, "append_test")
	results = append(results, check("APPEND new", func() (interface{}, error) {
		return rdb.Append(ctx, "append_test", "hello").Result()
	}, int64(5)))
	results = append(results, check("APPEND existing", func() (interface{}, error) {
		return rdb.Append(ctx, "append_test", " world").Result()
	}, int64(11)))
	results = append(results, check("GET append_test", func() (interface{}, error) {
		return rdb.Get(ctx, "append_test").Result()
	}, "hello world"))

	// STRLEN
	rdb.Set(ctx, "strlen_test", "hello", 0)
	results = append(results, check("STRLEN", func() (interface{}, error) {
		return rdb.StrLen(ctx, "strlen_test").Result()
	}, int64(5)))

	// SET NX
	rdb.Del(ctx, "nx_test")
	results = append(results, check("SET NX new", func() (interface{}, error) {
		return rdb.SetNX(ctx, "nx_test", "val1", 0).Result()
	}, true))
	results = append(results, check("SET NX existing", func() (interface{}, error) {
		return rdb.SetNX(ctx, "nx_test", "val2", 0).Result()
	}, false))

	// ECHO
	results = append(results, check("ECHO", func() (interface{}, error) {
		return rdb.Echo(ctx, "hello").Result()
	}, "hello"))

	// Cleanup
	cleanupKeys := []string{"foo", "del_test", "exists_test", "m1", "m2", "m3", "ms1", "ms2", "counter", "append_test", "strlen_test", "nx_test"}
	rdb.Del(ctx, cleanupKeys...)

	// Print results
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