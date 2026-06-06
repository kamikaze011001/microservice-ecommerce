#!/usr/bin/env sh
set -eu
# Seeds MongoDB (api_role + product + productQuantityHistory) for the k8s cluster.
# Idempotency = option A (count predicate), made fail-closed, plus a wait-for-
# PRIMARY preflight and a post-import verification so the Job can NEVER report
# success without the data actually landing (see the verify block at the end).
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
# Wait until mongod is the writable PRIMARY before touching data. A replica-set
# node that is briefly SECONDARY/RECOVERING right after bring-up (or stuck not-a-
# member after an IP change) rejects reads/writes with NotPrimaryOrSecondary
# (13436); seeding against it silently writes nothing. Fail loudly if it never
# becomes PRIMARY rather than letting the Job "succeed" empty.
echo "(seed) waiting for mongo PRIMARY ..."
i=0
until mongosh "$MONGO_URI" --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "(seed) ERROR: mongo not PRIMARY after 120s — aborting"
    exit 1
  fi
  sleep 2
done

# Idempotency guard (fail-closed). Capture mongosh's own exit code directly (the
# old `| tr` pipe masked it). Keep only digits; a clean numeric > 0 means already
# seeded. Anything else (empty / error text) ⇒ treat as NOT seeded and proceed —
# never skip on an ambiguous read.
COUNT=$(mongosh "$MONGO_URI" --quiet --eval \
  'db.getSiblingDB("ecommerce_inventory").api_role.countDocuments()' 2>/dev/null)
COUNT=$(printf '%s' "$COUNT" | tr -dc '0-9')
if [ -n "$COUNT" ] && [ "$COUNT" -gt 0 ]; then
  echo "(seed) mongo already seeded (api_role has ${COUNT} docs); skipping"
  exit 0
fi

echo "(seed) importing api_role, product, productQuantityHistory ..."
mongoimport --uri "$MONGO_URI" --jsonArray --db ecommerce_inventory --collection api_role --file /seed/api_role.json
mongoimport --uri "$MONGO_URI" --jsonArray --db ecommerce_inventory --collection product --file /seed/product.json
# Collection name MUST be productQuantityHistory (camelCase). product-service's
# entity is `@Document` with no explicit name, so Spring derives the collection
# from the class ProductQuantityHistory → productQuantityHistory. Importing into
# product_quantity_history (snake, the JSON filename style) leaves the app
# reading an EMPTY collection → quantity sum null → product detail showed 0 /
# 500'd. (product + api_role use @Document("product"/"api_role") so they're fine.)
mongoimport --uri "$MONGO_URI" --jsonArray --db ecommerce_inventory --collection productQuantityHistory --file /seed/product-quantity-history.json

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

# Post-import verification — the durable guard against a silent "Job complete but
# nothing written" success (the failure that left this cluster's gateway 403ing
# on every route). Assert the auth rules and catalog actually landed; exit non-
# zero otherwise so `kubectl wait --for=condition=complete` surfaces it instead
# of the cluster coming up with an empty api_role.
echo "(seed) verifying imported counts ..."
VERIFY=$(mongosh "$MONGO_URI" --quiet --eval '
  var d = db.getSiblingDB("ecommerce_inventory");
  var a = d.api_role.countDocuments();
  var p = d.product.countDocuments();
  var q = d.productQuantityHistory.countDocuments();
  print(a + " " + p + " " + q + (a > 0 && p > 0 ? " OK" : " FAIL"));
' 2>/dev/null)
echo "(seed) counts api_role/product/productQuantityHistory: ${VERIFY}"
case "$VERIFY" in
  *OK) echo "(seed) mongo seed complete" ;;
  *)   echo "(seed) ERROR: verification failed — api_role/product empty after import"; exit 1 ;;
esac
