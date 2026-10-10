package org.aibles.ecommerce.devbox_portal.service;

import org.aibles.ecommerce.devbox_portal.client.GiteaClient;
import org.aibles.ecommerce.devbox_portal.client.MetricsClient;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.DeployResult;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.EnvView;
import org.aibles.ecommerce.devbox_portal.dto.PortalViews.TagView;

import java.util.List;

public interface EnvService {

    /** Every env in the env repo, each service with its pinned tag and Argo CD status. */
    List<EnvView> envs();

    /** Pin {@code service} in {@code env} to {@code tag}: one commit to the env repo — the portal's only write. */
    DeployResult deploy(String env, String service, String tag);

    /** The env's change log: commits touching envs/{env}/, newest first. */
    List<GiteaClient.Commit> history(String env, int limit);

    /** The service's registry tags, each with the envs that pin it. */
    List<TagView> tags(String service);

    List<MetricsClient.PerfRun> perfRuns();
}
