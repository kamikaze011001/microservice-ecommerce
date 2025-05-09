package org.aibles.gateway.entity;

import lombok.Data;
import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.mapping.Document;

import java.util.List;

@Data
@Document(value = "api_role")
public class ApiRole {

    @Id
    private String id;

    private String path;

    private List<String> method;

    private List<String> roles;
}
