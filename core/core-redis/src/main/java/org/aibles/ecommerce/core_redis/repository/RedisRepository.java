package org.aibles.ecommerce.core_redis.repository;

import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.TimeUnit;

public interface RedisRepository {

    void save(String key, Object value, long timeToLive, TimeUnit timeUnit);

    void save(String key, Object value);

    void incr(String key, long delta);

    void decr(String key, long delta);

    void save(String key, String hashKey, Object value);

    <T> void add(String key, T value, Class<T> clazz);

    <T> void add(String key, Set<T> values, Class<T> clazz);

    Optional<Object> get(String key, String hashKey);

    Optional<Object> get(String key);

    <T> Set<T> members(String key, Class<T> clazz);

    void delete(String key, String hashKey);

    void delete(String key);

    <T> void remove(String key, T value);

    <T> void remove(String key, Set<T> values);

    Optional<Map<String, Long>> getMapStringLong(String key);

    Optional<Long> getLong(String key);

    Optional<Double> getDouble(String key);

    Optional<String> getString(String key);

    Optional<Integer> getInteger(String key);
}
