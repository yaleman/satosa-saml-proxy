# SATOSA based SAML to Kanidm OIDC proxy

i.e. How to connect legacy web apps that only support SAML to be backed by Kanidm OIDC. While the configs in this repo can be educational for rolling your own SATOSA setup, an opinionated ENV configurable container image is also provided.
This example on purpose only supports a 1:1 proxy config where a single SAML supporting web service auths via a single OIDC endpoint. To limit blast radius, just deploy multiple if you have multiple SAML-only services.

> [!NOTE]
> If you want to just skip to the part where we use this with Kanidm, you could jump straight to the practical example: [Ceph SSO via Kanidm](#practical-example-ceph-sso-via-kanidm)

## TODO items on the roadmap
1. Get rid of the idpyoidc git build once there's a release that contains ES256 support.
2. Get rid of any manual jiggery with idpyoidc once SATOSA requires a sufficiently high version to support ES256.

## The container

The container built at `ghcr.io/jinnatar/satosa-saml-proxy:latest` is a proof of concept using the SATOSA configs in the repo. The guides below will assume you are using it, but nothing prevents you from using the same configs and ENV config with any other supported SATOSA installation method. I am using the container myself in my environment and have a vested interest in keeping it going and tested.

### The caveats with the container and/or trying to go without it:
- While recent releases of SATOSA support PKCE, they depend on the Python library `idpyoidc` for this. Unfortunately it has an issue that prevents using `ES256` for signing with released versions. The container thus uses [a branch from git](https://github.com/IdentityPython/idpy-oidc/tree/issuer_metadata) that contains the fix for this. Once a full release is made with said fix that will be used specifically. Once SATOSA requires a high enough release of `idpyoidc` that contains a fix, we can stop with this nonsense altogether.
- The containers are now version tagged as per SATOSA upstream versions. However, due to the above nonsense those tags will be updated later when better build provenance is available.

### Container config options
The container contains minimal config options via environment variables for ease of use.
- `LOG_LEVEL`: defaults to `INFO`. You may want to raise this to `DEBUG` for troubleshooting, but be aware logs will then leak tokens. Affects gunicorn and all SATOSA modules (if using the env based default config).
- `LISTEN_ADDR`: defaults to `0.0.0.0:80`. You may need to alter this depending on your container orchestration and proxying needs.
- Any other gunicorn flags can be passed as arguments.

## Step by step guides for usage

SAML is a bit *involved* so we need to prep a persistent certificate and provide metadata for the system you will auth for. We'll first cover generic steps and then go over them again with a practical example setting up SSO for Ceph.

### Generic steps
1. Generate your SAML2 certs, be sure to select the validity days and provide your own SN matching the proxy domain.
   ```shell
   openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
        -keyout saml.key -out saml.crt -subj "/SN=saml.example.com/"
   ```
1. Give read access to your key: `chown :999 saml.key && chmod g+r saml.key` .. This way SATOSA is limited to only read.
1. Get your target SAML side system's metadata XML file. How to do this is specific to the app you're setting up! This isn't just a static file, it will need details specific to your installation so it's common to have an endpoint you can `curl` to generate it. You may not be able to generate it until you've registered the proxy's metadata on the app side, in this case leave `SAML_METADATA=dummy-metadata.xml` to get the proxy running first and then circle back once you get the real data.
1. Once you have your metadata XML file, make it available to your container, for example via a volume. The dummy data is already available.
2. Configure the ENV variables that will tweak the provided SATOSA configs. You can edit the provided `example.env` file and feed it to Docker via the `--env-file` flag. Make sure to **not** quote values if using that flag. Explanations below:
   ```shell
   # Enables debug logging for troubleshooting.
   # Change this to "INFO" when everything works!
   LOG_LEVEL=DEBUG  # Enables debug logging for troubleshooting. Change this to "INFO" when everything works!

   # Key used to encrypt state in transit. Use a key of your own choosing!
   # For example, generate one with `openssl rand -base64 32`  
   ENCRYPTION_KEY=0xDEADBEEF
   # The OIDC client id in Kanidm is the name of the integration, for example `ceph`.
   OIDC_CLIENT_ID=your-client-id
   OIDC_CLIENT_SECRET=your-oidc-client-secret  
   
   # Full URL to the discovery endpoint  
   OIDC_ISSUER_URL=https://idm.example.com/oauth2/openid/your-client-id

   # A unique id used for the OIDC side in SATOSA, used in the callback URL: `https://ceph.example.com/unique_oidc_name`
   OIDC_NAME=unique_oidc_name
   # A unique id used for the SAML side in SATOSA, used in URLs.
   SAML_NAME=unique_saml_name
   
   # Where your proxy lives. **must** be https, must be the root of a host with no subdir,
   # must match the CN in your cert from step 1, must be unique per app you're integrating.
   PROXY_BASE_URL=https://saml.example.com
   
   # A path to your app SAML metadata file.
   # The working directory of the provided image is `/etc/satosa`,
   # so the relative path example here would expect the file to be on the container at `/etc/satosa/dummy-metadata.xml`.
   # If you can't get this until the proxy is running and you've registered it in the app, use dummy-metadata.xml as a workaround to boot the proxy without it.  
   SAML_METADATA=dummy-metadata.xml
   
   ```
3. Launch the proxy. This depends on your container orchestration, but a simple testing example is provided below. **This is not enough, you need to get https working which is outside the scope of this guide.
   ```shell
   # Assuming a reverse proxy will handle TLS from https://saml.example.com
   docker run --rm -it -p 8080:80 \
    --env-file example.env \
    -v $PWD/saml.crt:/etc/satosa/saml.crt -v $PWD/saml.key:/etc/satosa/saml.key  \
    -v $PWD/your-app-metadata.xml:/etc/satosa/your-app-metadata.xml \
    ghcr.io/jinnatar/satosa-saml-proxy:latest

   # Let gunicorn handle TLS, otherwise the same, just add at the end after the image name:
    --keyfile=<https key> --certfile=<https cert>
   ```
4. Register the proxy with your app to enable SAML based SSO. This is highly dependent on your app but the proxy endpoint that spits out your bespoke metadata will be: `https://saml.example.com/unique_saml_name/metadata.xml`
5. Test and monitor your app, proxy and iDP logs if anything goes wrong!

### Practical example: Ceph SSO via Kanidm
1. Pre-create your users in Ceph to give them the correct authz. In this example we'll use short usernames for simplicity so that needs to match.
1. Create your Kanidm OIDC configuration the usual way, no need to disable PKCE!
   ```shell
   # **Important** give the upstream Ceph landing page URL here:
   kanidm system oauth2 create ceph Ceph https://ceph.example.com

   # **Important** give the proxy callback URL here. The full value depends on $OIDC_NAME:
   kanidm system oauth2 add-redirect-url ceph https://ceph-saml.example.com/oidc_ceph

   # Use short usernames for convenience
   kanidm system oauth2 prefer-short-username ceph

   # Create the scope map, don't forget to create the group and add your Ceph admins to it.
   kanidm system oauth2 update-scope-map ceph ceph_admins openid profile email  

   # Get your client_secret for use later on:
   kanidm system oauth2 show-basic-secret ceph
   ```
1. Create your SAML2 certs and set their permissions, remember to set the correct `SN`:
   ```shell
      openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
           -keyout saml.key -out saml.crt -subj "/SN=ceph-saml.example.com/"
      chown :999 saml.key
      chmod g+r saml.key
   ```
1. We can't get Ceph to spit out it's metadata XML before the proxy is functioning so we skip ahead.
1. Config your ENV variables into a new env file, `ceph.env`. If you don't change the ENCRYPTION_KEY value you deserve everything you get as a result.
   ```shell
   # Enables debug logging for troubleshooting. Change this to "INFO" when everything works!
   LOG_LEVEL=DEBUG
   # Generate this for example with: `openssl rand -base64 32`
   ENCRYPTION_KEY=
   OIDC_CLIENT_ID=ceph
   # The client secret you got in a previous step: 
   OIDC_CLIENT_SECRET=
   OIDC_ISSUER_URL=https://idm.example.com/oauth2/openid/ceph
   OIDC_NAME=oidc_ceph
   PROXY_BASE_URL=https://ceph-saml.example.com
   SAML_METADATA=dummy-metadata.xml
   SAML_NAME=saml_ceph
   ```
1. Launch the proxy with your configured ENV:
   ```shell
   docker run --rm -it -p 8080:80 \
    --env-file ceph.env \
    -v $PWD/saml.crt:/etc/satosa/saml.crt -v $PWD/saml.key:/etc/satosa/saml.key  \
    ghcr.io/jinnatar/satosa-saml-proxy:latest
   ```
1. Register the proxy with Ceph, giving it the Ceph URL, SAML metadata endpoint and an attribute field name to expect for the username.
   ```shell
   ceph dashboard sso setup saml2 \
    https://ceph.example.com \
    https://ceph-saml.example.com/saml_ceph/metadata.xml \
    urn:oid:0.9.2342.19200300.100.1.1
   ```
1. Assuming registration was succesful, we can now get the Ceph side SAML metadata:
   ```shell
   curl https://ceph.example.com/auth/saml2/metadata > ceph-metadata.xml
   ```
   And can now amend `ceph.env` with: `SAML_METADATA=ceph-metadata.xml` and restart the proxy, this time adding an extra mount for the real Ceph metadata:
   ```shell
   docker run --rm -it -p 8080:80 \
    --env-file ceph.env \
    -v $PWD/saml.crt:/etc/satosa/saml.crt -v $PWD/saml.key:/etc/satosa/saml.key  \
    -v $PWD/ceph-metadata.xml:/etc/satosa/ceph-metadata.xml \
    ghcr.io/jinnatar/satosa-saml-proxy:latest
    ```

1. Restart the proxy and go test Ceph SSO! Once it's all working, amend your env one more time to set `LOG_LEVEL=INFO`!
