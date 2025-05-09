package org.aibles.ecommerce.common_dto.request;

import jakarta.validation.constraints.Min;
import lombok.Data;

@Data
public class PagingRequest {

    public static final int DEFAULT_PAGE_SIZE = 10;
    public static final int DEFAULT_PAGE_NUM = 1;
    @Min(1)
    private Integer page = DEFAULT_PAGE_NUM;

    @Min(1)
    private Integer size = DEFAULT_PAGE_SIZE;
}
