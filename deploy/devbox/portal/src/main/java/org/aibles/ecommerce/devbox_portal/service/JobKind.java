package org.aibles.ecommerce.devbox_portal.service;

import java.util.Arrays;
import java.util.List;
import java.util.regex.Pattern;

/**
 * What the portal can run, and nothing else: each kind maps to one devbox.sh
 * command with fixed arguments, so a request can never smuggle in a command
 * line. The runner Job executes the same script `make devbox-*` does.
 */
public enum JobKind {

    ENV_CREATE("env-create", "Create preview env"),
    ENV_DELETE("env-delete", "Delete preview env");

    /** env_gen.py's preview grammar: preview-<1-20 chars>. */
    private static final Pattern PREVIEW = Pattern.compile("preview-[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?");

    private final String id;
    private final String title;

    JobKind(String id, String title) {
        this.id = id;
        this.title = title;
    }

    public String id() {
        return id;
    }

    public String title() {
        return title;
    }

    public static JobKind of(String id) {
        return Arrays.stream(values()).filter(k -> k.id.equals(id)).findFirst()
                .orElseThrow(() -> new IllegalArgumentException("unknown job kind '" + id + "'"));
    }

    /** "cart" or "preview-cart" → "preview-cart"; anything else is rejected. */
    public String normalizeTarget(String target) {
        String t = target == null ? "" : target.trim();
        if (!t.startsWith("preview-")) {
            t = "preview-" + t;
        }
        if (!PREVIEW.matcher(t).matches()) {
            throw new IllegalArgumentException("env name must be 1-20 of a-z, 0-9, '-' (not at the ends), got '" + target + "'");
        }
        return t;
    }

    /** The devbox.sh arguments for this kind. env-delete's trailing 1 = APPLY (not a dry run). */
    public List<String> args(String target) {
        return switch (this) {
            case ENV_CREATE -> List.of("env-create", target);
            case ENV_DELETE -> List.of("env-delete", target, "1");
        };
    }
}
