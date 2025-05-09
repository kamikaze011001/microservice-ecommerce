package org.aibles.ecommerce.inventory_service.grpc.server;

import io.grpc.Server;
import io.grpc.ServerBuilder;
import lombok.extern.slf4j.Slf4j;
import org.aibles.ecommerce.inventory_service.service.InventoryService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import java.io.IOException;
import java.util.concurrent.TimeUnit;

@Slf4j
@Component
public class InventoryGrpcServer {

    @Value("${grpc.server.port:9090}")
    private int port;

    private final InventoryGprcService inventoryGrpcService;

    private Server server;

    public InventoryGrpcServer(InventoryService inventoryService) {
        this.inventoryGrpcService = new InventoryGprcService(inventoryService);
    }

    @PostConstruct
    public void start() throws IOException {
        server = ServerBuilder.forPort(port)
                .addService(inventoryGrpcService)
                .build()
                .start();
        log.info("gRPC Server started, listening on port {}", port);

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            log.info("Shutting down gRPC server");
            try {
                InventoryGrpcServer.this.stop();
            } catch (InterruptedException e) {
                log.error("Error during server shutdown", e);
            }
        }));
    }

    @PreDestroy
    public void stop() throws InterruptedException {
        if (server != null) {
            server.shutdown().awaitTermination(30, TimeUnit.SECONDS);
        }
    }
}