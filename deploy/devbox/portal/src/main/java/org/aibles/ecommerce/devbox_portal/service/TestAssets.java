package org.aibles.ecommerce.devbox_portal.service;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.List;

/** The repo's test assets baked into the portal image: the Bruno collection and the k6 scenarios. */
public interface TestAssets {

    /** One .bru file, path relative to api-tests/ ("02 Auth/login.bru"). */
    record BrunoFile(String path, String content) {
    }

    /**
     * What a perf run of {@code scenario}/{@code profile} will do, as k6 itself
     * resolves it ({@code k6 inspect --execution-requirements}): scenarios
     * (executor, VUs, stages, duration…) and thresholds; plus the script's own
     * description and the request names it tags.
     */
    record PerfSettings(String scenario, String profile, String script, String description, String overrides,
                        JsonNode scenarios, JsonNode thresholds, List<String> requests) {
    }

    List<BrunoFile> brunoFiles();

    PerfSettings perfSettings(String scenario, String profile);
}
