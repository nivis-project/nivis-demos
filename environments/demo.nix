# The `demo` environment — the catstack `infra_environments/` role. Every domain
# function receives this attrset as `env`.
#
# THIS REPO IS PUBLIC. Every account-specific value below is deliberately FAKE.
# That is the end state, not a TODO: a clone substitutes its own values before
# applying anything. Credentials never appear here at all — they come from the
# standard chains (AWS profile / environment, HCLOUD_TOKEN).
{
  name = "demo";

  aws = {
    # Safe to publish: a region is not account-specific.
    region = "eu-central-1";
  };

  # Remote state (the catstack .tfbackend role). Each domain appends its own
  # `key`; see stack/000_backend for the bucket itself.
  backend = {
    type = "s3";

    # FAKE ON PURPOSE, and deliberately *invalid* rather than merely unowned:
    # `_` and uppercase are outside S3's bucket-naming grammar, so AWS rejects
    # this immediately instead of creating something under a name you did not
    # choose — and a plausible-looking name would be squattable, turning every
    # clone's first apply into a confusing BucketAlreadyExists from a bucket
    # nobody here controls. Replace it with your own globally-unique name.
    bucket = "REPLACE_ME-nivis-demos-state";

    region = "eu-central-1";
  };

  tags = {
    ManagedBy = "nivis";
    Project = "nivis-demos";
    Environment = "demo";
  };
}
