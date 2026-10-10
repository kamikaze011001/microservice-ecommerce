package org.aibles.ecommerce.devbox_portal.service;

import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Reads and rewrites {@code apps.<svc>.image.tag} in an env-repo service file.
 *
 * <p>A text edit, not a YAML round-trip, on purpose: people write comments in the
 * env repo, and parse → serialize would drop every one of them on the first
 * deploy from the portal. Same shape as {@code set_tag} in deploy/devbox/devbox.sh,
 * so the CLI and the portal produce identical diffs.
 */
public final class ImageTag {

    // `    image:` then `      tag: <value>` — 4 and 6 spaces, as env_gen.py and
    // the seed files write them. Anything else is refused rather than guessed.
    // Groups: 1 the key, 2 the value, 3 the rest of the line (spacing + an
    // optional `# comment`, kept as-is), 4 the line end.
    private static final Pattern TAG_LINE =
            Pattern.compile("(\\n    image:\\n      tag:)[ \\t]*([^\\s#]+)([^\\n]*)(\\n|$)");

    /** Docker tag grammar; also keeps a path or YAML out of a commit. */
    public static final Pattern VALID_TAG = Pattern.compile("[A-Za-z0-9_][A-Za-z0-9._-]{0,127}");

    private ImageTag() {
    }

    public static Optional<String> current(String serviceFile) {
        Matcher m = TAG_LINE.matcher(serviceFile);
        return m.find() ? Optional.of(m.group(2)) : Optional.empty();
    }

    public static String withTag(String serviceFile, String tag) {
        if (!VALID_TAG.matcher(tag).matches()) {
            throw new IllegalArgumentException("not a valid image tag: " + tag);
        }
        Matcher m = TAG_LINE.matcher(serviceFile);
        if (!m.find()) {
            throw new IllegalArgumentException("no `image.tag` line in this service file");
        }
        return serviceFile.substring(0, m.start())
                + m.group(1) + " " + tag + m.group(3) + m.group(4)
                + serviceFile.substring(m.end());
    }
}
