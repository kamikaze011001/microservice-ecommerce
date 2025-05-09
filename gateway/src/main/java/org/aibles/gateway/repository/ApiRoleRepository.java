package org.aibles.gateway.repository;

import org.aibles.gateway.entity.ApiRole;
import org.springframework.data.mongodb.repository.ReactiveMongoRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface ApiRoleRepository extends ReactiveMongoRepository<ApiRole, String> {
}
