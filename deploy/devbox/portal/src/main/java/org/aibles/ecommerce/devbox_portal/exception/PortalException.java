package org.aibles.ecommerce.devbox_portal.exception;

import org.springframework.http.HttpStatus;

/** An error the portal reports to its page as-is: a status and one sentence. */
public class PortalException extends RuntimeException {

    private final HttpStatus status;

    public PortalException(HttpStatus status, String message) {
        super(message);
        this.status = status;
    }

    public PortalException(HttpStatus status, String message, Throwable cause) {
        super(message, cause);
        this.status = status;
    }

    public HttpStatus status() {
        return status;
    }

    public static PortalException notFound(String message) {
        return new PortalException(HttpStatus.NOT_FOUND, message);
    }

    /** The request is well-formed but can't be applied (e.g. tag not in the registry). */
    public static PortalException unprocessable(String message) {
        return new PortalException(HttpStatus.UNPROCESSABLE_ENTITY, message);
    }

    /** Someone else changed the file since we read it. */
    public static PortalException conflict(String message) {
        return new PortalException(HttpStatus.CONFLICT, message);
    }

    /** Gitea / registry / Kubernetes / VictoriaMetrics failed. */
    public static PortalException upstream(String what, Throwable cause) {
        return new PortalException(HttpStatus.BAD_GATEWAY, what + " is unreachable or failed: " + cause.getMessage(), cause);
    }
}
