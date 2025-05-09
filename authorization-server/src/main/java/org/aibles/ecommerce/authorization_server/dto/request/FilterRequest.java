package org.aibles.ecommerce.authorization_server.dto.request;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.Valid;
import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.aibles.ecommerce.authorization_server.dto.QueryModel;
import org.aibles.ecommerce.authorization_server.dto.SortModel;

import java.util.List;

@Data
@NoArgsConstructor
@AllArgsConstructor
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public class FilterRequest {

    @Valid
    private List<QueryModel> query;

    @Valid
    private List<SortModel> sort;
}
