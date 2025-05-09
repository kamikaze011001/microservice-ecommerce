package org.aibles.ecommerce.authorization_server.util;

import java.security.SecureRandom;
import java.util.Base64;

public class GeneratorUtil {

    private static int OTP_LENGTH = 6;

    public static String generateOtp() {
        SecureRandom random = new SecureRandom();
        int bound = (int) Math.pow(10, OTP_LENGTH) - 1;
        int otp = random.nextInt(bound);
        return String.format("%06d", otp);
    }

    public static String generateResetPassKey(String email, String otp) {
        return Base64.getEncoder().encodeToString((email + ":" + otp).getBytes());
    }
}
