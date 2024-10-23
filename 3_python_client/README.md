
# Running STAC Catalog Demo

## Starting the Project Outside of Docker

To run the `2_stac_catalog` project outside of Docker, follow these steps:

1. **Create a Python Virtual Environment**:
   - Navigate to the `2_stac_catalog` directory.
   - Create a virtual environment using the following command:

     ```sh
     python -m venv venv
     ```

2. **Activate the Virtual Environment**:
   - On macOS and Linux:

     ```sh
     source venv/bin/activate
     ```

   - On Windows:

     ```sh
     .\venv\Scripts\activate
     ```

3. **Install Dependencies**:
   - With the virtual environment activated, install the required dependencies:

     ```sh
     pip install -r requirements.txt
     ```

4. **Source .env vars**:
   - To put env vars into your environment go into the .env file and change ES_HOST to localhost, then run:

    ```sh
      source .env
    ```

5. **Start the Application**:
   - From 2_stac-demo, run:

     ```sh
     cd stac_fastapi/opensearch/stac_fastapi/opensearch && uvicorn app:app --reload
     ```

## Using Docker Compose

To run the `2_stac_catalog` project using Docker Compose, follow these steps:

1. **Launch the Application**:
   - Use Docker Compose to spin up the application:

     ```sh
     docker compose up
     ```

## Deploying the Application in Production Mode

To deploy the application in production mode, follow these steps:

1. **Build the Container**:
   - Build the Docker container using the following command:

     ```sh
     docker build -f ./dockerfiles/Dockerfile.deploy.os -t stac-backend .
     ```

2. **Run the Container**:
   - Pull the container into your desired environment and run the application:

     ```sh
     docker run -p 8080:8080 \
       -e ES_USE_SSL=true \
       -e ES_HOST=address-of-lucenia-cluster \
       -e ES_PORT=443 \
       -e ES_USER=admin \
       -e ES_VERIFY_CERTS=false \
       -e ES_PASS=MyStrongPassword123! \
       -e STAC_FASTAPI_ROUTE_DEPENDENCIES='[{"routes":[{"method":"*","path":"*"}],"dependencies":[{"method":"stac_fastapi.core.basic_auth.BasicAuth","kwargs":{"credentials":[{"username":"admin","password":"admin"}]}}]}]' \
       stac-backend
     ```

## Adding Sample STAC Data

To add sample STAC catalog data to the Lucenia node, run the following command from inside the virtual environment:

```sh
python3 data_loader.py --base-url http://localhost:8082 --username admin --password admin
```

## Additional Information

- Ensure that you have Docker and Docker Compose installed on your machine.
- Make sure to activate the virtual environment whenever you work on the `2_stac_catalog` project to ensure that the correct dependencies are used.

