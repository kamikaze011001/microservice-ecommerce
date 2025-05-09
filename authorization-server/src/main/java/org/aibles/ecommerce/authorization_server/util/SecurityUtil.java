package org.aibles.ecommerce.authorization_server.util;

import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;

public class SecurityUtil {

    private static final String SYSTEM_ID = "SYSTEM";

    private SecurityUtil() {}

    public static String getUserId() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null) {
            return SYSTEM_ID;
        }
        return (String) auth.getPrincipal();
    }

    public static String getEmail() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null) {
            return SYSTEM_ID;
        }
        return (String) auth.getCredentials();
    }
}
