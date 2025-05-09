package org.aibles.ecommerce.authorization_server.constant;

import lombok.Getter;

import java.util.HashMap;
import java.util.Map;

@Getter
public enum OTPType {

    ACTIVE_ACCOUNT(CacheConstant.Otp.ACTIVE_ACCOUNT, CacheConstant.Otp.ACTIVE_ACCOUNT_MINUTE, "Active account OTP"),
    FORGOT_PASSWORD(CacheConstant.Otp.FORGOT_PASSWORD, CacheConstant.Otp.FORGOT_PASSWORD_MINUTE, "Forgot password OTP");

    private final String redisKey;

    private final Integer minute;

    private final String mailSubject;

    private static final Map<String, OTPType> valueMap = new HashMap<>();

    OTPType(String type, Integer minute, String mailSubject) {
        this.redisKey = type;
        this.minute = minute;
        this.mailSubject = mailSubject;
    }

    static {
        for (OTPType type : OTPType.values()) {
            valueMap.put(type.redisKey, type);
        }
    }

    public static OTPType resolve(String key) {
        return valueMap.get(key);
    }
}
