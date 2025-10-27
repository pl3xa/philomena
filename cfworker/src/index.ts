import {Image} from "./image";
import {PutExposed} from "./types";

export {Image};

function filenameWithoutQuery(filename: string): string {
  let input_filename_url = new URL("https://example.example/" + filename);
  return input_filename_url.pathname.substring(1);
}


async function handleAdmin(request, env, ctx): Promise<Response> {
  const adminPattern = new URLPattern({pathname: "/exposed/:image_id"});
  const adminMatch = adminPattern.exec(new URL(request.url));

  const {image_id} = adminMatch!.pathname.groups;

  const objectId: DurableObjectId = env.IMAGE_OBJECT.idFromName(image_id);

  const stub = env.IMAGE_OBJECT.get(objectId);

  // TODO validate cloudflare access

  switch (request.method) {
    case "GET":
      return new Response(JSON.stringify((await stub.getAdminToJson())));
    case "PUT":
      if ((await stub.existingObject())) {
        return new Response("Already exists", {status: 400});
      }
      let json = await request.json<PutExposed>();
      if (!json.filename) {
        return new Response("Bad body", {status: 400});
      }

      let postdata = JSON.stringify(json);
      let clean_filename = filenameWithoutQuery(json.filename);

      stub.generateSecret();
      await stub.setFields(image_id, clean_filename, postdata);

      return new Response(JSON.stringify((await stub.getAdminToJson())), {status: 201});
    default:
      return new Response("Unimplemented", {status: 400});
  }
}

export default {

  /**
   * This is the standard fetch handler for a Cloudflare Worker
   *
   * @param request - The request submitted to the Worker from the client
   * @param env - The interface to reference bindings declared in wrangler.jsonc
   * @param ctx - The execution context of the Worker
   * @returns The response to be sent back to the client
   */
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);

    const pattern = new URLPattern({pathname: "/:image_id/:secret/:filename"});
    const match = pattern.exec(url);

    if (!match) {
      const adminPattern = new URLPattern({pathname: "/exposed/:image_id"});
      const adminMatch = adminPattern.exec(url);
      if (adminMatch) {
        return handleAdmin(request, env, ctx);
      }

      return new Response("Not found", {status: 404});
    }

    const {image_id, secret, filename} = match.pathname.groups;

    const objectId: DurableObjectId = env.IMAGE_OBJECT.idFromName(image_id);

    const stub = env.IMAGE_OBJECT.get(objectId);

    // so below func checks if this should be an image we return
    if (!(await stub.isValidGet(secret, filename))) {
      return new Response("Not found.", {status: 404});
    }

    return new Response(
      JSON.stringify({image_id, secret, filename}),
      {headers: {"content-type": "application/json"}}
    );


    // Call the `sayHello()` RPC method on the stub to invoke the method on
    // the remote Durable Object instance
    const greeting = await stub.sayHello();

    return new Response(greeting);
  },
} satisfies ExportedHandler<Env>;

