package org.aibles.ecommerce.authorization_server.repository.slave;

import org.aibles.ecommerce.authorization_server.dto.QueryModel;
import org.aibles.ecommerce.authorization_server.dto.SortModel;
import org.aibles.ecommerce.authorization_server.entity.User;

import java.util.List;

public interface UserRepositoryCustom {

    List<User> filter(List<QueryModel> query, List<SortModel> sort);
}
