package org.aibles.ecommerce.devbox_portal.client;

import com.fasterxml.jackson.databind.JsonNode;
import org.aibles.ecommerce.devbox_portal.configuration.PortalProperties;
import org.aibles.ecommerce.devbox_portal.exception.PortalException;
import org.springframework.http.HttpStatus;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;

/**
 * The env repo (devbox/env-config) through Gitea's REST API. The portal never
 * clones: it reads files by path and writes ONE file per change, guarded by the
 * blob sha it read — if someone pushed in between, Gitea refuses and so do we.
 */
public class GiteaClient {

    public record RepoFile(String path, String content, String sha) {
    }

    /** A branch of the code repo: its head commit. */
    public record Branch(String name, String sha, String message, String author, String date) {
    }

    public record Commit(String sha, String message, String author, String date) {
    }

    private final RestClient http;
    private final PortalProperties.Gitea cfg;

    public GiteaClient(RestClient http, PortalProperties.Gitea cfg) {
        this.http = http;
        this.cfg = cfg;
    }

    /**
     * The contents-API URL for a repo path. The path goes in as literal segments,
     * NOT as a {@code {path}} template variable: Spring encodes a variable's "/"
     * as %2F and Gitea answers 404 for every file. Safe because every path here
     * is built from names PortalController validated ([a-z0-9-]).
     */
    private static String contents(String path) {
        if (!path.matches("[a-z0-9./_-]+") || path.contains("..")) {
            throw new IllegalArgumentException("unexpected env-repo path: " + path);
        }
        return "/api/v1/repos/{o}/{r}/contents/" + path;
    }

    /** Names of the entries of {@code type} (dir | file) under {@code dir}. */
    public List<String> list(String dir, String type) {
        try {
            JsonNode entries = http.get()
                    .uri(contents(dir) + "?ref={b}", cfg.owner(), cfg.envRepo(), cfg.branch())
                    .retrieve().body(JsonNode.class);
            List<String> names = new ArrayList<>();
            if (entries != null) {
                entries.forEach(e -> {
                    if (type.equals(e.path("type").asText())) {
                        names.add(e.path("name").asText());
                    }
                });
            }
            return names;
        } catch (HttpClientErrorException.NotFound e) {
            throw PortalException.notFound("no " + dir + " in the env repo");
        } catch (RestClientException e) {
            throw PortalException.upstream("Gitea", e);
        }
    }

    public RepoFile read(String path) {
        return readAt(path, cfg.branch());
    }

    /** {@code path} as it was at {@code ref} (a branch or a commit sha). */
    public RepoFile readAt(String path, String ref) {
        try {
            JsonNode f = http.get()
                    .uri(contents(path) + "?ref={b}", cfg.owner(), cfg.envRepo(), ref)
                    .retrieve().body(JsonNode.class);
            // Gitea wraps base64 at 60 columns; the MIME decoder ignores the newlines.
            String content = new String(Base64.getMimeDecoder().decode(f.path("content").asText()), StandardCharsets.UTF_8);
            return new RepoFile(path, content, f.path("sha").asText());
        } catch (HttpClientErrorException.NotFound e) {
            throw PortalException.notFound(path + " is not in the env repo");
        } catch (RestClientException e) {
            throw PortalException.upstream("Gitea", e);
        }
    }

    /** Replace {@code file} with {@code content}; returns the new commit's sha. */
    public String update(RepoFile file, String content, String subject, String body) {
        Map<String, Object> request = Map.of(
                "content", Base64.getEncoder().encodeToString(content.getBytes(StandardCharsets.UTF_8)),
                "sha", file.sha(),
                "branch", cfg.branch(),
                "message", subject + "\n\n" + body,
                // Same author as the runner's commits: history says the portal made it.
                "author", Map.of("name", "devbox-portal", "email", "devbox-portal@microecom.local"));
        try {
            JsonNode res = http.put()
                    .uri(contents(file.path()), cfg.owner(), cfg.envRepo())
                    .body(request)
                    .retrieve().body(JsonNode.class);
            return res.path("commit").path("sha").asText();
        } catch (HttpClientErrorException e) {
            // A stale sha: the file changed after we read it (another portal tab,
            // a CLI ship, a hand-edit). Re-read and decide again — never overwrite.
            if (e.getStatusCode().isSameCodeAs(HttpStatus.CONFLICT)
                    || e.getStatusCode().isSameCodeAs(HttpStatus.UNPROCESSABLE_ENTITY)) {
                throw PortalException.conflict(file.path() + " changed since it was read — reload and try again");
            }
            throw PortalException.upstream("Gitea", e);
        } catch (RestClientException e) {
            throw PortalException.upstream("Gitea", e);
        }
    }

    /** Branches developers pushed to the code repo, most recently updated first. */
    public List<Branch> codeBranches() {
        try {
            JsonNode list = http.get().uri("/api/v1/repos/{o}/{r}/branches?limit=50", cfg.owner(), cfg.codeRepo())
                    .retrieve().body(JsonNode.class);
            List<Branch> out = new ArrayList<>();
            if (list != null) {
                list.forEach(b -> {
                    JsonNode c = b.path("commit");
                    out.add(new Branch(b.path("name").asText(), c.path("id").asText(),
                            c.path("message").asText().strip().split("\n", 2)[0],
                            c.path("author").path("name").asText(), c.path("timestamp").asText()));
                });
            }
            out.sort(java.util.Comparator.comparing(Branch::date).reversed());
            return out;
        } catch (HttpClientErrorException.NotFound e) {
            return List.of();
        } catch (RestClientException e) {
            throw PortalException.upstream("Gitea", e);
        }
    }

    /** The first parent of {@code sha} (the state a change was made on top of). */
    public String parent(String sha) {
        try {
            JsonNode c = http.get().uri("/api/v1/repos/{o}/{r}/git/commits/{s}?stat=false&files=false",
                    cfg.owner(), cfg.envRepo(), sha).retrieve().body(JsonNode.class);
            JsonNode parents = c == null ? null : c.path("parents");
            if (parents == null || parents.isEmpty()) {
                throw PortalException.unprocessable("commit " + sha + " has no parent to go back to");
            }
            return parents.get(0).path("sha").asText();
        } catch (HttpClientErrorException.NotFound e) {
            throw PortalException.notFound("no commit " + sha + " in the env repo");
        } catch (RestClientException e) {
            throw PortalException.upstream("Gitea", e);
        }
    }

    public List<Commit> commits(String path, int limit) {
        try {
            JsonNode list = http.get()
                    .uri("/api/v1/repos/{o}/{r}/commits?sha={b}&path={p}&limit={n}&stat=false&verification=false&files=false",
                            cfg.owner(), cfg.envRepo(), cfg.branch(), path, limit)
                    .retrieve().body(JsonNode.class);
            List<Commit> out = new ArrayList<>();
            if (list != null) {
                // Gitea ignores `limit` when the query is filtered by `path`
                // (seen live: limit=3 returned 12), so the cap is enforced here.
                list.forEach(c -> {
                    if (out.size() >= limit) {
                        return;
                    }
                    out.add(new Commit(
                        c.path("sha").asText(),
                        c.path("commit").path("message").asText().strip(),
                        c.path("commit").path("author").path("name").asText(),
                        c.path("commit").path("author").path("date").asText()));
                });
            }
            return out;
        } catch (RestClientException e) {
            throw PortalException.upstream("Gitea", e);
        }
    }
}
