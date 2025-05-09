package org.aibles.ecommerce.authorization_server.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class QueryModel {

    @NotBlank
    private String field;

    @Pattern(regexp = "eq|ne|lt|gt|ge|le|like")
    private String operation;

    @NotBlank
    private String value;
}
