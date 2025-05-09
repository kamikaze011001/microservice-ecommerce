package org.aibles.ecommerce.common_dto.response;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class PagingResponse {

    private int page;

    private int size;

    private long total;

    private Object data;
}
