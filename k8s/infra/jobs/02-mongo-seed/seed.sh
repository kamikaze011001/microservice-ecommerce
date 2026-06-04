#!/usr/bin/env sh
set -eu
# TODO (Checkpoint 6 — HUMAN): write idempotency + seed logic.
#
# Available in this container:
#   - mongosh, mongoimport (mongo:7.0, Docker Official)
#   - $MONGO_URI : full connection string with auth
#   - $MONGO_DB  : ecommerce_inventory
#   - /seed/api_role.json
#   - /seed/product.json
#   - /seed/product-quantity-history.json
#
# Three idempotency options to choose from (see plan Task 13 / Checkpoint 6):
#   A) Count predicate — `db.api_role.countDocuments() > 0` ⇒ skip.
#      Simple, mirrors the MySQL Job. Fragile if anyone hand-deletes a row.
#   B) Sentinel marker — insert {_id: "_seed_marker", at: <ts>} after seeding;
#      check for it on next run. Survives partial collection edits but adds
#      a fake doc that downstream code must ignore.
#   C) Content hash — store sha256 of the source JSON files in
#      ecommerce_inventory._seed_meta; re-seed only if hash changes.
#      Best when seed data evolves; most code to write.
#
# Once decided, replace this body. Target collections:
#   api_role               ← /seed/api_role.json               (--jsonArray)
#   product                ← /seed/product.json                (--jsonArray)
#   product_quantity_history ← /seed/product-quantity-history.json (--jsonArray)
COUNT=$(mongosh "$MONGO_URI" --quiet --eval \
'db.getSiblingDB("ecommerce_inventory").api_role.countDocuments()' \
| tr -d '[:space:]')
if [ "${COUNT:-0}" -gt 0 ]; then
  echo "mongo already seeded (api_role has ${COUNT} docs); skipping"
  exit 0
fi
mongoimport --uri "$MONGO_URI"  --jsonArray --db ecommerce_inventory --collection api_role --file /seed/api_role.json
mongoimport --uri "$MONGO_URI"  --jsonArray --db ecommerce_inventory --collection product --file /seed/product.json
# Collection name MUST be productQuantityHistory (camelCase). product-service's
# entity is `@Document` with no explicit name, so Spring derives the collection
# from the class ProductQuantityHistory → productQuantityHistory. Importing into
# product_quantity_history (snake, the JSON filename style) leaves the app
# reading an EMPTY collection → quantity sum null → product detail showed 0 /
# 500'd. (product + api_role use @Document("product"/"api_role") so they're fine.)
mongoimport --uri "$MONGO_URI"  --jsonArray --db ecommerce_inventory --collection productQuantityHistory --file /seed/product-quantity-history.json

# Rewrite the product image host for k8s. docker/product.json hardcodes
# http://localhost:9000/... (the docker-compose host port). In kind the browser
# reaches MinIO through the media.microecom.local ingress, so swap the host.
# Field is `imageUrl` (camelCase as stored in Mongo; it serializes to image_url
# on the wire via @JsonNaming(SnakeCase) — matching image_url here would rewrite
# nothing). Kept here, not in product.json, so the JSON stays shared with docker.
mongosh "$MONGO_URI" --quiet --eval '
  var d = db.getSiblingDB("ecommerce_inventory");
  d.product.find({ imageUrl: /^http:\/\/localhost:9000\// }).forEach(function (p) {
    d.product.updateOne(
      { _id: p._id },
      { $set: { imageUrl: p.imageUrl.replace("http://localhost:9000/", "http://media.microecom.local/") } }
    );
  });
  print("imageUrl host rewritten to media.microecom.local");
'
echo "mongo seed complete"
