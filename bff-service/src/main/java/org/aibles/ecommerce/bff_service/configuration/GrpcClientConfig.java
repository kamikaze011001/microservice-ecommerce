package org.aibles.ecommerce.bff_service.configuration;

import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import org.aibles.ecommerce.bff_service.client.InventoryGrpcClientService;
import org.aibles.ecommerce.inventory.grpc.InventoryServiceGrpc;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class GrpcClientConfig {

    @Value("${inventory.grpc.host}")
    private String grpcHost;

    @Value("${inventory.grpc.port}")
    private int grpcPort;

    @Bean
    public ManagedChannel managedChannel() {
        return ManagedChannelBuilder.forAddress(grpcHost, grpcPort)
                .usePlaintext()
                .build();
    }

    @Bean
    public InventoryServiceGrpc.InventoryServiceBlockingStub inventoryStub(ManagedChannel channel) {
        return InventoryServiceGrpc.newBlockingStub(channel);
    }

    @Bean
    public InventoryGrpcClientService inventoryGrpcClientService(
            InventoryServiceGrpc.InventoryServiceBlockingStub stub) {
        return new InventoryGrpcClientService(stub);
    }
}
