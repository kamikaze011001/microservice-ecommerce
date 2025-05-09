package org.aibles.ecommerce.orchestrator_service.dto;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class EventDTO {

    private String id;

    private String name;

    private Object data;
}
