import { createDirectus, rest, authentication, readMe, createRole, createPolicy, updateRole, createPermission, readPolicies } from '@directus/sdk';

const client = createDirectus('http://127.0.0.1:8055')
  .with(authentication('json'))
  .with(rest());

const roleId = '64f31dc8-7465-4416-b1eb-ef6efd990de9';
const policyId = '9f7f3f4c-bb3a-4c0e-9a2d-2f0e7e4d9b01';


async function run() {
  console.log("Logging in as admin...");

  await client.login({
    email: process.env.ADMIN_EMAIL,
    password: process.env.ADMIN_PASSWORD
  });

  const me = await client.request(
    readMe({
      fields: ["*", "role.*"]
    })
  );

  console.log('Logged in as', me.email);

  console.log("Creating policy...");

  try {
    await client.request(createPolicy({
      id: policyId,
      name: 'Content Manager Policy',
      icon: 'supervised_user_circle',
      icon: 'supervised_user_circle',
      description: 'Policy granting app access',
      app_access: true,
      admin_access: false
    }));
  } catch (err) {
    console.error("Error creating policy:", err);
  }

  console.log("Creating role...");

  let cmPolicy = null

  try {
    cmPolicy = await client.request(createRole({
      id: roleId,
      name: 'Content Manager',
      icon: 'supervised_user_circle',
      description: 'Automatically created role for multi-species content management',
    }));
  } catch (err) {
    console.error("Error creating role:", err);
  }

  console.log("Attach policy to role...");

  try {
    await client.request(updateRole(roleId, {
      policies: [{ policy: policyId }]
    }))
  } catch (err) {
    console.error("Error update role:", err);
  }

  console.log("Creating permissions...");

  const collections = [ 'logo', 'color', 'examples', 'site_info', 'homepage', 'links', 'resource_sections']
  const actions = ['create', 'read', 'update', 'delete']

  await Promise.all(
    collections.concat(['directus_folders', 'directus_files']).flatMap(collection =>
      actions.map(action =>
        client.request(createPermission({
          collection,
          action,
          fields: ['*'],
          policy: policyId
        }))
      )
    )
  );

  let publicPolicy = null

  try {
    publicPolicy  = (await client.request(readPolicies({
      search: 'public'
    })))[0]
  } catch {}

  const publicActions = ['read']

  await Promise.all(
    collections.concat(['directus_files']).flatMap(collection =>
      publicActions.map(action =>
        client.request(createPermission({
          collection,
          action,
          fields: ['*'],
          policy: publicPolicy.id
        }))
      )
    )
  );

  console.log("Bootstrap complete");
  client.stopRefreshing();
}


run().catch((err) => {
  console.error(err);
  client.stopRefreshing();
});
