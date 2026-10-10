package org.aibles.ecommerce.devbox_portal.service;

import org.aibles.ecommerce.devbox_portal.dto.PortalViews.ToolView;

import java.util.List;

/** The platform's other UIs and how to log in to them. */
public interface ToolService {

    List<ToolView> tools();
}
