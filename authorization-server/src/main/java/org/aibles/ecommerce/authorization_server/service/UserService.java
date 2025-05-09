package org.aibles.ecommerce.authorization_server.service;

import org.aibles.ecommerce.authorization_server.dto.request.FilterRequest;
import org.aibles.ecommerce.authorization_server.dto.request.UpdateUserRequest;
import org.aibles.ecommerce.authorization_server.dto.response.UserDetailResponse;
import org.aibles.ecommerce.authorization_server.entity.User;

import java.util.List;

public interface UserService {

    boolean isExistedByEmail(String email);

    User save(String email);

    void update(String userId, UpdateUserRequest request);

    UserDetailResponse get(String userId);

    List<UserDetailResponse> filter(FilterRequest request);
}
