const { S3Client, ListObjectsV2Command, GetObjectCommand, CreateBucketCommand, HeadBucketCommand } = require('@aws-sdk/client-s3');
const { Client } = require('@opensearch-project/opensearch'); // Lucenia uses OpenSearch APIs
const fs = require('fs');
const path = require('path');
const { promisify } = require('util');
const https = require('https');

require('dotenv').config();

// MinIO Configuration
const s3 = new S3Client({
  endpoint: process.env.MINIO_ENDPOINT || 'http://localhost:9000',
  region: 'us-east-1',
  credentials: {
    accessKeyId: process.env.MINIO_ACCESS_KEY || 'minioadmin',
    secretAccessKey: process.env.MINIO_SECRET_KEY || 'minioadmin',
  },
  forcePathStyle: true,
});

// Lucenia Configuration
const luceniaClient = new Client({
  node: process.env.LUCENIA_URL || 'https://localhost:9201',
  auth: {
    username: 'admin',
    password: process.env.LUCENIA_INITIAL_ADMIN_PASSWORD || 'MyStrongPassword123!',
  },
  agent: () =>
    new https.Agent({
      rejectUnauthorized: false, // Ignore invalid SSL certificates
    }),
});

// Constants
const BUCKET_NAME = process.env.DOCS_BUCKET || 'legal-docs';
const INGEST_PROCESSOR_NAME = process.env.INGEST_PROCESSOR_NAME || 'document_ingest';
const INDEX_NAME = process.env.DOCUMENT_INDEX || 'documents';
const POLLING_INTERVAL = parseInt(process.env.POLLING_INTERVAL || '5000', 10);
const PROCESSED_FILES_DIR = '../scratch/processed_files';

// Ensure processed files directory exists
if (fs.existsSync(PROCESSED_FILES_DIR) == false) {
  fs.mkdirSync(PROCESSED_FILES_DIR);
}

// Helper: Save file locally
const saveFile = async (key, body) => {
  const filePath = path.join(PROCESSED_FILES_DIR, key);
  const writeFile = promisify(fs.writeFile);
  await writeFile(filePath, body);
  return filePath;
};

// Helper: Base64 encode file content
const encodeFileToBase64 = (filePath) => {
  const fileContent = fs.readFileSync(filePath);
  return fileContent.toString('base64');
};

// Ensure bucket exists or create it
const ensureBucketExists = async () => {
  try {
    await s3.send(new HeadBucketCommand({ Bucket: BUCKET_NAME }));
    console.log(`Bucket "${BUCKET_NAME}" already exists.`);
  } catch (err) {
    if (err.name === 'NotFound') {
      console.log(`Bucket "${BUCKET_NAME}" does not exist. Creating it...`);
      await s3.send(new CreateBucketCommand({ Bucket: BUCKET_NAME }));
      console.log(`Bucket "${BUCKET_NAME}" created successfully.`);
    } else {
      console.error('Error checking bucket existence:', err);
      throw err;
    }
  }
};

// Process new files
const processNewFiles = async () => {
  try {
    const command = new ListObjectsV2Command({ Bucket: BUCKET_NAME });
    const { Contents } = await s3.send(command);

    if (Contents && Contents.length > 0) {
      for (const file of Contents) {
        const filePath = path.join(PROCESSED_FILES_DIR, file.Key);

        // Skip already processed files
        if (fs.existsSync(filePath)) {
          continue;
        }

        console.log(`Processing new file: ${file.Key}`);

        // Download file from S3
        const getObjectCommand = new GetObjectCommand({
          Bucket: BUCKET_NAME,
          Key: file.Key,
        });
        const fileData = await s3.send(getObjectCommand);
        const fileBody = await streamToBuffer(fileData.Body);

        // Save file locally
        const localFilePath = await saveFile(file.Key, fileBody);

        // Convert to Base64
        const base64Content = encodeFileToBase64(localFilePath);

        // log
	console.log(`Downloaded file: ${file.Key}, Size: ${fileBody.length} bytes`);
        console.log(`Base64 Content Snippet: ${base64Content.substring(0, 100)}`);
	console.log(`Base64 Content Length: ${base64Content.length}`);
	console.log(`Original File Size: ${fs.statSync(filePath).size}`);


	// Send to Lucenia for indexing
        const indexPayload = {
          index: INDEX_NAME,
          pipeline: INGEST_PROCESSOR_NAME,
          body: {
            base64_data: base64Content,
            filename: file.Key,
          },
        };

        const indexResponse = await luceniaClient.index(indexPayload);

	// Check the response status and log appropriate messages
        if (indexResponse.statusCode === 201 &&  indexResponse.body.result === 'created') {
          console.log(`Successfully indexed file: ${file.Key} into index: ${INDEX_NAME}`);
        } else {
          console.error(`Unexpected response while indexing file: ${file.Key}`, indexResponse);
	}
      }
    } else {
      console.log('No new files to process.');
    }
  } catch (error) {
    console.error('Error processing files:', error);
  }
};

// Convert stream to buffer
const streamToBuffer = async (stream) => {
  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
};

// Monitor S3 bucket for new files
const monitorBucket = async () => {
  await ensureBucketExists();
  console.log(`Monitoring bucket "${BUCKET_NAME}" for new files...`);
  setInterval(processNewFiles, POLLING_INTERVAL);
};

// Initialize
monitorBucket();

