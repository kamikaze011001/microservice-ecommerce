package org.aibles.ecommerce.authorization_server.constant;

public class CacheConstant {

    public static final String SEPARATOR_KEY = "_";

    public static class Otp {
        public static final String ACTIVE_ACCOUNT = "active_account";
        public static final int ACTIVE_ACCOUNT_MINUTE = 3;
        public static final String FORGOT_PASSWORD = "forgot_password";
        public static final int FORGOT_PASSWORD_MINUTE = 3;
    }

    public static final String RESET_PASSWORD_KEY = "reset_password";
}
