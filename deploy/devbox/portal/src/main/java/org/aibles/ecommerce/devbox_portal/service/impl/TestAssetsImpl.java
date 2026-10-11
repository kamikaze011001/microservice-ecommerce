package org.aibles.ecommerce.devbox_portal.service.impl;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.aibles.ecommerce.devbox_portal.service.JobKind;
import org.aibles.ecommerce.devbox_portal.service.TestAssets;
import org.springframework.http.HttpStatus;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * Reads api-tests/ and deploy/k6-stress/ as baked into the portal image (the
 * same commit the runner image copies), so what the page shows is what a job
 * runs. Perf settings come from k6 itself, never re-typed: a hand-written
 * table would drift from the scripts the first time someone edits a stage.
 */
@Slf4j
public class TestAssetsImpl implements TestAssets {

    /** Mirrors perf.sh perf_script(). */
    private static final Map<String, String> SCRIPTS = Map.of(
            "payment", "payment-flow.js",
            "storefront", "storefront-flow.js");
    private static final Pattern REQUEST_NAME = Pattern.compile("name:\\s*['\"]([a-zA-Z0-9_]+)['\"]");

    private final Path apiTestsDir;
    private final Path k6Dir;
    private final String k6Binary;
    private final ObjectMapper json = new ObjectMapper();
    /** The scripts are baked into the image — a result never changes for this portal's lifetime. */
    private final Map<String, PerfSettings> cache = new ConcurrentHashMap<>();

    public TestAssetsImpl(Path apiTestsDir, Path k6Dir, String k6Binary) {
        this.apiTestsDir = apiTestsDir;
        this.k6Dir = k6Dir;
        this.k6Binary = k6Binary;
    }

    @Override
    public List<BrunoFile> brunoFiles() {
        if (!Files.isDirectory(apiTestsDir)) {
            throw PortalException.notFound("no API test collection in this portal image (" + apiTestsDir + ")");
        }
        try (Stream<Path> files = Files.walk(apiTestsDir)) {
            List<BrunoFile> out = new ArrayList<>();
            for (Path p : files.filter(f -> f.toString().endsWith(".bru"))
                    .filter(f -> !f.toString().contains("node_modules")).sorted().toList()) {
                out.add(new BrunoFile(apiTestsDir.relativize(p).toString(), Files.readString(p, StandardCharsets.UTF_8)));
            }
            return out;
        } catch (IOException e) {
            throw new PortalException(HttpStatus.INTERNAL_SERVER_ERROR, "cannot read the API test collection", e);
        }
    }

    @Override
    public PerfSettings perfSettings(String scenario, String profile) {
        JobKind.PERF.args("prod-like", Map.of("scenario", scenario, "profile", profile));   // validates both
        return cache.computeIfAbsent(scenario + "/" + profile, k -> inspect(scenario, profile));
    }

    private PerfSettings inspect(String scenario, String profile) {
        Path script = k6Dir.resolve(SCRIPTS.get(scenario));
        // Mirrors perf.sh perf_profile_args(): payment smoke = a CLI override
        // (K6_VUS/K6_DURATION are k6's env spelling of --vus/--duration);
        // storefront picks its shape from PROFILE.
        List<String> cmd = new ArrayList<>(List.of(k6Binary, "inspect", "--execution-requirements"));
        String overrides;
        ProcessBuilder pb = new ProcessBuilder();
        if (scenario.equals("payment") && profile.equals("smoke")) {
            pb.environment().put("K6_VUS", "3");
            pb.environment().put("K6_DURATION", "30s");
            overrides = "--vus 3 --duration 30s";
        } else if (scenario.equals("storefront")) {
            cmd.addAll(List.of("-e", "PROFILE=" + profile));
            overrides = "-e PROFILE=" + profile;
        } else {
            overrides = "";
        }
        cmd.add(script.toString());
        try {
            String source = Files.readString(script, StandardCharsets.UTF_8);
            Process p = pb.command(cmd).redirectErrorStream(false).start();
            byte[] out = p.getInputStream().readAllBytes();
            String err = new String(p.getErrorStream().readAllBytes(), StandardCharsets.UTF_8);
            if (!p.waitFor(30, TimeUnit.SECONDS) || p.exitValue() != 0) {
                throw new PortalException(HttpStatus.INTERNAL_SERVER_ERROR, "k6 inspect failed for " + scenario + "/" + profile + ": " + err.strip());
            }
            JsonNode options = json.readTree(out);
            return new PerfSettings(scenario, profile, script.getFileName().toString(), description(source), overrides,
                    options.path("scenarios"), options.path("thresholds"), requestNames(source));
        } catch (IOException e) {
            throw new PortalException(HttpStatus.INTERNAL_SERVER_ERROR, "cannot inspect " + script.getFileName() + ": " + e.getMessage(), e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new PortalException(HttpStatus.INTERNAL_SERVER_ERROR, "interrupted inspecting " + script.getFileName(), e);
        }
    }

    /** The script's leading comment block — each k6 script opens by saying what it exercises. */
    static String description(String source) {
        StringBuilder d = new StringBuilder();
        for (String line : source.split("\n")) {
            String t = line.strip();
            if (t.startsWith("//")) {
                d.append(t.replaceFirst("^//\\s?", "")).append('\n');
            } else if (!t.isEmpty() || !d.isEmpty()) {
                break;
            }
        }
        return d.toString().strip();
    }

    /** The k6 request tags (`name: 'login'`) — the rows a perf comparison shows. */
    static List<String> requestNames(String source) {
        LinkedHashSet<String> names = new LinkedHashSet<>();
        Matcher m = REQUEST_NAME.matcher(source);
        while (m.find()) {
            names.add(m.group(1));
        }
        return List.copyOf(names);
    }
}
