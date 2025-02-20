import opensearch from '@opensearch-project/opensearch/.';

const client = new opensearch.Client({
  node: 'https://localhost:9200',
  auth: {
    username: 'admin',
    password: 'myStrongPassword@123',
  },
  ssl: {
    rejectUnauthorized: false,
  },
});

const index_name = 'books';

const settings = {
  settings: {
    index: {
      number_of_shards: 4,
      number_of_replicas: 3,
    },
  },
};

async function run() {
  const indexExists = await client.indices.exists({
    index: index_name,
  });

  if (indexExists.body) {
    console.log('Index exists, deleting...');
    await client.indices
      .delete({
        index: index_name,
      })
      .then(() => {
        console.log('Index deleted');
      })
      .catch((err) => {
        console.log(err);
        process.exit(1);
      });
  }

  console.log('Creating index...');
  const response = await client.indices
    .create({
      index: index_name,
      body: settings,
    })
    .then(() => {
      console.log('Index created');
    })
    .catch((err) => {
      console.log(err);
      process.exit(1);
    });

  console.log('Adding document...');
  const insert = await client.index({
    index: index_name,
    body: {
      character: 'Ned Stark',
      quote: 'Winter is coming.',
    },
  });

  console.log('Searching...');
  const result = await client.search({
    index: index_name,
    body: {
      query: {
        match: {
          quote: {
            query: 'Winter is coming',
          },
        },
      },
    },
  });
  console.log(result.body.hits.hits);

  console.log('Deleting Document...');
  const deleteResponse = await client.delete({
    index: index_name,
    id: insert.body._id,
  });
  console.log(deleteResponse.body.result);

  console.log('Deleting Index...');
  const deleteIndexResponse = await client.indices.delete({
    index: index_name,
  });
  console.log(deleteIndexResponse.body.acknowledged);

  console.log('Closing client...');
  await client.close();
}

run();
