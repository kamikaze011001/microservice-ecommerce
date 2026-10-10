package org.aibles.ecommerce.devbox_portal.service;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * What the portal can run, and nothing else: each kind maps to one devbox.sh
 * command with fixed, validated arguments, so a request can never smuggle in a
 * command line. The runner Job executes the same script `make devbox-*` does.
 */
public enum JobKind {

    ENV_CREATE("env-create", "Create preview env"),
    ENV_DELETE("env-delete", "Delete preview env"),
    PERF("perf", "Perf test"),
    API_TEST("api-test", "API contract tests"),
    BUILD("build", "Build & deploy");

    /** env_gen.py's preview grammar: preview-<1-20 chars>. */
    private static final Pattern PREVIEW = Pattern.compile("preview-[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?");
    /** perf.sh's scenarios and the profiles each defines (perf_profile_args). */
    private static final Map<String, Set<String>> PERF_PROFILES = Map.of(
            "payment", Set.of("smoke", "load"),
            "storefront", Set.of("smoke", "soak", "stress"));

    private static final Pattern SERVICE = Pattern.compile("[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?");
    /** A git branch name, conservatively: no "..", no leading "-", no spaces or shell characters. */
    private static final Pattern REF = Pattern.compile("(?!-)(?!.*\\.\\.)[A-Za-z0-9._/-]{1,100}");

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

    public static Map<String, Set<String>> perfProfiles() {
        return PERF_PROFILES;
    }

    /**
     * The env this job acts on. Create/delete take a preview ("cart" or
     * "preview-cart" → "preview-cart"); tests run against prod-like or a preview.
     */
    public String normalizeTarget(String target) {
        String t = target == null ? "" : target.trim();
        if (t.equals("prod-like")) {
            if (this == PERF || this == API_TEST || this == BUILD) {
                return t;
            }
            // Not "preview-prod-like": the baseline is never created or deleted from here.
            throw new IllegalArgumentException("prod-like is the baseline env — it can't be created or deleted");
        }
        if (!t.startsWith("preview-")) {
            t = "preview-" + t;
        }
        if (!PREVIEW.matcher(t).matches()) {
            throw new IllegalArgumentException("env name must be 1-20 of a-z, 0-9, '-' (not at the ends), got '" + target + "'");
        }
        return t;
    }

    /** The devbox.sh arguments. env-delete's trailing 1 = APPLY (not a dry run). */
    public List<String> args(String env, Map<String, String> params) {
        return switch (this) {
            case ENV_CREATE -> List.of("env-create", env);
            case ENV_DELETE -> List.of("env-delete", env, "1");
            case API_TEST -> List.of("api-test", env);
            case BUILD -> {
                String service = params.getOrDefault("service", "");
                String ref = params.getOrDefault("ref", "");
                if (!SERVICE.matcher(service).matches()) {
                    throw new IllegalArgumentException("not a service name: '" + service + "'");
                }
                if (!REF.matcher(ref).matches()) {
                    throw new IllegalArgumentException("not a branch name: '" + ref + "'");
                }
                yield List.of("build-ship", service, env, ref);
            }
            case PERF -> {
                String scenario = params.getOrDefault("scenario", "");
                String profile = params.getOrDefault("profile", "smoke");
                Set<String> profiles = PERF_PROFILES.get(scenario);
                if (profiles == null) {
                    throw new IllegalArgumentException("scenario must be one of " + PERF_PROFILES.keySet());
                }
                if (!profiles.contains(profile)) {
                    throw new IllegalArgumentException("profile for " + scenario + " must be one of " + profiles);
                }
                yield List.of("perf", scenario, env, profile);
            }
        };
    }

    /** Builds talk to the node's Docker: host network + the Docker socket (JobServiceImpl). */
    public boolean needsDocker() {
        return this == BUILD;
    }

    /** A short label for lists: "Perf test · payment/smoke". */
    public String describe(Map<String, String> params) {
        return switch (this) {
            case PERF -> title + " · " + params.get("scenario") + "/" + params.get("profile");
            case BUILD -> title + " · " + params.get("service") + "@" + params.get("ref");
            default -> title;
        };
    }
}
