package org.aibles.payment_service.entity;

import lombok.Builder;
import lombok.Data;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.mapping.Document;

import java.time.LocalDateTime;

@Data
@Document
@Builder
public class Event {

    @Id
    private String id;

    private String name;

    private String data;

    @CreatedDate
    private LocalDateTime createdAt;
}
