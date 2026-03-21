package org.aibles.ecommerce.core_redis.repository.impl;

import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.core_redis.repository.RedisRepository;
import org.springframework.data.redis.core.RedisTemplate;

import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

@Slf4j
public class RedisRepositoryImpl implements RedisRepository {

    private final RedisTemplate<String, Object> redisTemplate;

    public RedisRepositoryImpl(RedisTemplate<String, Object> redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    @Override
    public void save(String key, Object value, long timeToLive, TimeUnit timeUnit) {
        redisTemplate.opsForValue().set(key, value, timeToLive, timeUnit);
    }

    @Override
    public void save(String key, Object value) {
        redisTemplate.opsForValue().set(key, value);
    }

    @Override
    public void incr(String key, long delta) {
        redisTemplate.opsForValue().increment(key, delta);
    }

    @Override
    public void decr(String key, long delta) {
        redisTemplate.opsForValue().decrement(key, delta);
    }

    @Override
    public void save(String key, String hashKey, Object value) {
        redisTemplate.opsForHash().put(key, hashKey, value);
    }

    @Override
    public <T> void add(String key, T value, Class<T> clazz) {
        redisTemplate.opsForSet().add(key, clazz.cast(value));
    }

    @Override
    public <T> void add(String key, Set<T> values, Class<T> clazz) {
        for (T value : values) {
            add(key, value, clazz);
        }
    }

    @Override
    public Optional<Object> get(String key, String hashKey) {
        return Optional.ofNullable(redisTemplate.opsForHash().get(key, hashKey));
    }

    @Override
    public Optional<Object> get(String key) {
        return Optional.ofNullable(redisTemplate.opsForValue().get(key));
    }

    @Override
    public <T> Set<T> members(String key, Class<T> clazz) {
        Set<Object> members = redisTemplate.opsForSet().members(key);

        if (members != null) {
            return members.stream()
                    .map(clazz::cast)
                    .collect(Collectors.toSet());
        }

        return Collections.emptySet();
    }

    @Override
    public void delete(String key, String hashKey) {
        redisTemplate.opsForHash().delete(key, hashKey);
    }

    @Override
    public void delete(String key) {
        redisTemplate.delete(key);
    }

    @Override
    public <T> void remove(String key, T value) {
        redisTemplate.opsForSet().remove(key, value);
    }

    @Override
    public <T> void remove(String key, Set<T> values) {
        redisTemplate.opsForSet().remove(key, values.toArray());
    }

    @Override
    public Optional<Map<String, Long>> getMapStringLong(String key) {
        Object value = redisTemplate.opsForValue().get(key);
        if (value == null) {
            return Optional.empty();
        }

        if (value instanceof Map<?, ?> rawMap) {
            try {
                Map<String, Long> typedMap = new HashMap<>();

                for (Map.Entry<?, ?> entry : rawMap.entrySet()) {
                    if (entry.getKey() instanceof String mapKey) {
                        if (entry.getValue() instanceof Number) {
                            typedMap.put(mapKey, ((Number) entry.getValue()).longValue());
                        } else {
                            log.warn("Value in map for key '{}' is not a number: {}",
                                    mapKey, entry.getValue() != null ? entry.getValue().getClass() : "null");
                        }
                    }
                }

                return Optional.of(typedMap);
            } catch (Exception e) {
                log.warn("Failed to convert map for key: {}", key, e);
                return Optional.empty();
            }
        }

        log.warn("Value for key: {} is not a Map: {}", key, value.getClass());
        return Optional.empty();
    }

    @Override
    public Optional<Long> getLong(String key) {
        Object value = redisTemplate.opsForValue().get(key);
        if (value == null) {
            return Optional.empty();
        }

        if (value instanceof Number number) {
            return Optional.of((number.longValue()));
        }

        log.warn("Value for key: {} is not a long: {}", key, value.getClass());
        return Optional.empty();
    }

    @Override
    public Optional<Double> getDouble(String key) {
        Object value = redisTemplate.opsForValue().get(key);
        if (value == null) {
            return Optional.empty();
        }

        if (value instanceof Number number) {
            return Optional.of(number.doubleValue());
        }

        log.warn("Value for key: {} is not a double: {}", key, value.getClass());
        return Optional.empty();
    }

    @Override
    public Optional<String> getString(String key) {
        Object value = redisTemplate.opsForValue().get(key);
        if (value == null) {
            return Optional.empty();
        }

        if (value instanceof String str) {
            return Optional.of(str);
        }

        log.warn("Value for key: {} is not a String: {}", key, value.getClass());
        return Optional.empty();
    }

    @Override
    public Optional<Integer> getInteger(String key) {
        Object value = redisTemplate.opsForValue().get(key);
        if (value == null) {
            return Optional.empty();
        }

        if (value instanceof Number number) {
            return Optional.of(number.intValue());
        }

        log.warn("Value for key: {} is not a number or parseable string: {}", key, value.getClass());
        return Optional.empty();
    }
}
