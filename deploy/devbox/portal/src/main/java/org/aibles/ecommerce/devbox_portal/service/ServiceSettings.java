package org.aibles.ecommerce.devbox_portal.service;

import org.yaml.snakeyaml.DumperOptions;
import org.yaml.snakeyaml.Yaml;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;
import java.util.regex.Pattern;

/**
 * A service's settings in an env-repo file — {@code apps.<svc>.springConfig}
 * (Spring properties, nested; the chart deep-merges it over
 * defaults.springConfig and renders SPRING_APPLICATION_JSON) and
 * {@code apps.<svc>.env} (plain container env vars).
 *
 * <p>The page edits Spring properties as flat keys. A map key that itself
 * contains dots (Kafka group ids: {@code group-id.payment.success}) is written
 * in Spring's bracket notation, {@code application.kafka.group-id[payment.success]},
 * so it round-trips — splitting it on the dots would bind a look-alike key
 * (root CLAUDE.md, "per-env config goes through springConfig").
 */
public final class ServiceSettings {

    /** Spring property path: segments, optionally [bracketed] map keys. */
    public static final Pattern SPRING_KEY = Pattern.compile("[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+|\\[[A-Za-z0-9_.\\-]+\\])*");
    public static final Pattern ENV_KEY = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");
    private static final Pattern SECRET_KEY = Pattern.compile(
            "(password|passwd|secret|token|api[-_]?key|private[-_]?key|credential|client[-_]?secret)", Pattern.CASE_INSENSITIVE);

    private ServiceSettings() {
    }

    /** Nested map → {"a.b.c": "v", "a.map[dotted.key]": "v"} (sorted). Lists flatten to [i]. */
    public static Map<String, String> flatten(Object node) {
        Map<String, String> out = new TreeMap<>();
        flatten("", node, out);
        return out;
    }

    @SuppressWarnings("unchecked")
    private static void flatten(String prefix, Object node, Map<String, String> out) {
        if (node instanceof Map<?, ?> map) {
            for (Map.Entry<String, Object> e : ((Map<String, Object>) map).entrySet()) {
                String k = String.valueOf(e.getKey());
                String path = k.contains(".") ? prefix + "[" + k + "]" : (prefix.isEmpty() ? k : prefix + "." + k);
                flatten(path, e.getValue(), out);
            }
        } else if (node instanceof List<?> list) {
            for (int i = 0; i < list.size(); i++) {
                flatten(prefix + "[" + i + "]", list.get(i), out);
            }
        } else if (!prefix.isEmpty()) {
            out.put(prefix, node == null ? "" : String.valueOf(node));
        }
    }

    /** The inverse of {@link #flatten} for maps (values stay strings; Spring converts them). */
    public static Map<String, Object> unflatten(Map<String, String> flat) {
        Map<String, Object> root = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : new TreeMap<>(flat).entrySet()) {
            List<String> parts = segments(e.getKey());
            Map<String, Object> cur = root;
            for (int i = 0; i < parts.size() - 1; i++) {
                Object next = cur.get(parts.get(i));
                if (!(next instanceof Map)) {
                    next = new LinkedHashMap<String, Object>();
                    cur.put(parts.get(i), next);
                }
                @SuppressWarnings("unchecked") Map<String, Object> m = (Map<String, Object>) next;
                cur = m;
            }
            cur.put(parts.get(parts.size() - 1), e.getValue());
        }
        return root;
    }

    /** "a.b[c.d].e" → [a, b, c.d, e]. */
    static List<String> segments(String key) {
        List<String> parts = new ArrayList<>();
        StringBuilder cur = new StringBuilder();
        for (int i = 0; i < key.length(); i++) {
            char c = key.charAt(i);
            if (c == '[') {
                if (!cur.isEmpty()) {
                    parts.add(cur.toString());
                    cur.setLength(0);
                }
                int end = key.indexOf(']', i);
                parts.add(key.substring(i + 1, end));
                i = end;
            } else if (c == '.') {
                if (!cur.isEmpty()) {
                    parts.add(cur.toString());
                    cur.setLength(0);
                }
            } else {
                cur.append(c);
            }
        }
        if (!cur.isEmpty()) {
            parts.add(cur.toString());
        }
        return parts;
    }

    /**
     * Refuses what must never reach git: secrets (they live in Vault, and the
     * env repo is readable by anyone with the devbox), and the one env var the
     * chart owns. Returns nothing; throws IllegalArgumentException with a reason.
     */
    public static void validate(Map<String, String> spring, Map<String, String> env) {
        spring.forEach((k, v) -> {
            if (!SPRING_KEY.matcher(k).matches()) {
                throw new IllegalArgumentException("'" + k + "' is not a Spring property name (use a.b.c, or a.map[dotted.key])");
            }
            refuseSecret(k, v);
        });
        env.forEach((k, v) -> {
            if (!ENV_KEY.matcher(k).matches()) {
                throw new IllegalArgumentException("'" + k + "' is not an env var name (letters, digits, _; not starting with a digit)");
            }
            if (k.equals("SPRING_APPLICATION_JSON")) {
                throw new IllegalArgumentException("SPRING_APPLICATION_JSON is generated from the Spring properties — set those instead");
            }
            refuseSecret(k, v);
        });
    }

    private static void refuseSecret(String key, String value) {
        String last = segments(key.toLowerCase(Locale.ROOT)).stream().reduce((a, b) -> b).orElse(key);
        String v = value == null ? "" : value;
        if (SECRET_KEY.matcher(last).find() || v.startsWith("-----BEGIN") || v.matches("eyJ[A-Za-z0-9_-]{10,}\\..*")) {
            throw new IllegalArgumentException("'" + key + "' looks like a secret — secrets stay in Vault, never in the env repo (git history keeps them forever)");
        }
    }

    /**
     * {@code content} with apps.&lt;svc&gt;.springConfig / env replaced (removed
     * when empty). Everything else in the file — image tag, resources, hpa — and
     * its leading comment block are kept.
     */
    @SuppressWarnings("unchecked")
    public static String withSettings(String content, String service, Map<String, String> spring, Map<String, String> env) {
        Map<String, Object> doc = load(content);
        Map<String, Object> apps = (Map<String, Object>) doc.computeIfAbsent("apps", k -> new LinkedHashMap<>());
        Map<String, Object> svc = (Map<String, Object>) apps.computeIfAbsent(service, k -> new LinkedHashMap<>());
        if (spring.isEmpty()) {
            svc.remove("springConfig");
        } else {
            svc.put("springConfig", unflatten(spring));
        }
        if (env.isEmpty()) {
            svc.remove("env");
        } else {
            svc.put("env", new TreeMap<>(env));
        }
        return header(content) + dump(doc);
    }

    /** apps.&lt;svc&gt;.{springConfig, env} of a file, flattened. */
    @SuppressWarnings("unchecked")
    public static Map<String, Map<String, String>> read(String content, String service) {
        Map<String, Object> doc = load(content);
        Map<String, Object> apps = (Map<String, Object>) doc.getOrDefault("apps", Map.of());
        Map<String, Object> svc = apps.get(service) instanceof Map<?, ?> m ? (Map<String, Object>) m : Map.of();
        Map<String, String> env = new TreeMap<>();
        if (svc.get("env") instanceof Map<?, ?> e) {
            e.forEach((k, v) -> env.put(String.valueOf(k), v == null ? "" : String.valueOf(v)));
        }
        return Map.of("spring", flatten(svc.get("springConfig")), "env", env);
    }

    /** defaults.springConfig of an env.yaml, flattened (what every service inherits). */
    @SuppressWarnings("unchecked")
    public static Map<String, String> inheritedSpring(String envYaml) {
        Map<String, Object> doc = load(envYaml);
        Map<String, Object> defaults = (Map<String, Object>) doc.getOrDefault("defaults", Map.of());
        return flatten(defaults.get("springConfig"));
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> load(String content) {
        Object o = new Yaml().load(content);
        return o instanceof Map<?, ?> m ? new LinkedHashMap<>((Map<String, Object>) m) : new LinkedHashMap<>();
    }

    private static String dump(Map<String, Object> doc) {
        DumperOptions opts = new DumperOptions();
        opts.setDefaultFlowStyle(DumperOptions.FlowStyle.BLOCK);
        opts.setIndent(2);
        opts.setWidth(200);
        return new Yaml(opts).dump(doc);
    }

    private static String header(String content) {
        StringBuilder h = new StringBuilder();
        for (String line : content.split("\n", -1)) {
            if (!line.startsWith("#")) {
                break;
            }
            h.append(line).append('\n');
        }
        return h.toString();
    }
}
