package org.aibles.ecommerce.devbox_portal.client;

import com.fasterxml.jackson.databind.JsonNode;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/** Perf runs recorded by `make devbox-perf` — one devbox_perf_run sample each, in VictoriaMetrics. */
public class MetricsClient {

    /** {@code exitCode} 0 = the run's k6 thresholds held. */
    public record PerfRun(String run, String env, String scenario, String profile, String durationSeconds,
                          String versions, int exitCode) {
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
}
