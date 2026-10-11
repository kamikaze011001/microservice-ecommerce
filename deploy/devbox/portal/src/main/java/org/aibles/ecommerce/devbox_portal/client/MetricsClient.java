package org.aibles.ecommerce.devbox_portal.client;

import com.fasterxml.jackson.databind.JsonNode;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeSet;

/** Perf runs (the portal's Perf page or `make devbox-perf`) — one devbox_perf_run sample each, in VictoriaMetrics. */
public class MetricsClient {

    /** {@code exitCode} 0 = the run's k6 thresholds held. */
    public record PerfRun(String run, String env, String scenario, String profile, String durationSeconds,
                          String versions, int exitCode) {
    }

    /** One request name in two runs (k6 tag `name`). p95 in seconds, err as a 0..1 rate. */
    public record RequestStats(String name, Double p95A, Double p95B, Double errA, Double errB,
                               Long reqsA, Long reqsB, boolean fewRequests) {
    }

    public record VersionChange(String service, String a, String b) {
    }

    public record PerfComparison(PerfRun a, PerfRun b, List<RequestStats> requests, List<VersionChange> versionChanges) {
    }

    private final RestClient http;

    public MetricsClient(RestClient http) {
        this.http = http;
    }

    public List<PerfRun> perfRuns() {
        try {
            JsonNode res = http.get()
                    .uri(u -> u.path("/api/v1/query").queryParam("query", "last_over_time(devbox_perf_run[90d])").build())
                    .retrieve().body(JsonNode.class);
            List<PerfRun> runs = new ArrayList<>();
            if (res != null) {
                res.path("data").path("result").forEach(r -> {
                    JsonNode m = r.path("metric");
                    runs.add(new PerfRun(m.path("run").asText(), m.path("env").asText(), m.path("scenario").asText(),
                            m.path("profile").asText(), m.path("duration_s").asText(), m.path("versions").asText(),
                            (int) Double.parseDouble(r.path("value").path(1).asText("-1"))));
                });
            }
            runs.sort(Comparator.comparing(PerfRun::run).reversed());
            return runs;
        } catch (RestClientException e) {
            throw PortalException.upstream("VictoriaMetrics", e);
        }
    }

    /**
     * The same figures as `make devbox-perf-compare`: per request name, the
     * run's overall p95, error rate and request count (k6 keeps trends
     * cumulative, so a run's LAST sample is its overall figure; setup requests
     * excluded), plus which service versions differ between the two runs.
     */
    public PerfComparison compare(String runA, String runB) {
        List<PerfRun> runs = perfRuns();
        PerfRun a = runs.stream().filter(r -> r.run().equals(runA)).findFirst()
                .orElseThrow(() -> PortalException.notFound("no recorded perf run " + runA));
        PerfRun b = runs.stream().filter(r -> r.run().equals(runB)).findFirst()
                .orElseThrow(() -> PortalException.notFound("no recorded perf run " + runB));

        Map<String, Double> p95a = perName("k6_http_req_duration_p95", runA, "max");
        Map<String, Double> p95b = perName("k6_http_req_duration_p95", runB, "max");
        Map<String, Double> erra = perName("k6_http_req_failed_rate", runA, "max");
        Map<String, Double> errb = perName("k6_http_req_failed_rate", runB, "max");
        Map<String, Double> reqa = perName("k6_http_reqs_total", runA, "sum");
        Map<String, Double> reqb = perName("k6_http_reqs_total", runB, "sum");

        List<RequestStats> rows = new ArrayList<>();
        TreeSet<String> names = new TreeSet<>(p95a.keySet());
        names.addAll(p95b.keySet());
        for (String n : names) {
            Long ra = reqa.containsKey(n) ? Math.round(reqa.get(n)) : null;
            Long rb = reqb.containsKey(n) ? Math.round(reqb.get(n)) : null;
            // A p95 over a handful of requests swings tens of percent between two
            // runs of the SAME code — flagged so it doesn't read as a finding.
            boolean few = (ra == null ? 0 : ra) < 30 || (rb == null ? 0 : rb) < 30;
            rows.add(new RequestStats(n, p95a.get(n), p95b.get(n), erra.get(n), errb.get(n), ra, rb, few));
        }
        return new PerfComparison(a, b, rows, versionChanges(a.versions(), b.versions()));
    }

    static List<VersionChange> versionChanges(String va, String vb) {
        Map<String, String> ma = versions(va);
        Map<String, String> mb = versions(vb);
        TreeSet<String> services = new TreeSet<>(ma.keySet());
        services.addAll(mb.keySet());
        List<VersionChange> out = new ArrayList<>();
        for (String s : services) {
            if (!Objects.equals(ma.get(s), mb.get(s))) {
                out.add(new VersionChange(s, ma.get(s), mb.get(s)));
            }
        }
        return out;
    }

    private static Map<String, String> versions(String csv) {
        Map<String, String> m = new LinkedHashMap<>();
        if (csv != null && !csv.isBlank()) {
            for (String pair : csv.split(",")) {
                String[] kv = pair.split("=", 2);
                if (kv.length == 2) {
                    m.put(kv[0], kv[1]);
                }
            }
        }
        return m;
    }

    private Map<String, Double> perName(String metric, String run, String agg) {
        String promql = agg + " by (name) (last_over_time(" + metric + "{devbox_run=\"" + run
                + "\",group!=\"::setup\"}[90d]))";
        try {
            // {q} is a URI-template variable: PromQL's own braces would otherwise be read as one.
            JsonNode res = http.get().uri(u -> u.path("/api/v1/query").queryParam("query", "{q}").build(promql))
                    .retrieve().body(JsonNode.class);
            Map<String, Double> out = new LinkedHashMap<>();
            if (res != null) {
                res.path("data").path("result").forEach(r -> {
                    String v = r.path("value").path(1).asText("");
                    if (!v.isEmpty() && !v.equals("NaN")) {
                        out.put(r.path("metric").path("name").asText(), Double.parseDouble(v));
                    }
                });
            }
            return out;
        } catch (RestClientException e) {
            throw PortalException.upstream("VictoriaMetrics", e);
        }
    }
}
