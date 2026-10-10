package org.aibles.ecommerce.devbox_portal.service;

import org.aibles.ecommerce.devbox_portal.dto.PortalViews.JobView;

import java.util.List;

/** Long-running platform work (create/delete an env, …) as Kubernetes Jobs the page can watch. */
public interface JobService {

    JobView start(String kind, String target);

    /** Newest first. */
    List<JobView> jobs();

    JobView job(String name);

    /** The runner's output so far ("" while its pod is still starting). */
    String log(String name);
}
