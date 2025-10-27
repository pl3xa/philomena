import {DurableObject, env} from "cloudflare:workers";
import {generateSecret} from "./helpers";

/** A Durable Object's behavior is defined in an exported Javascript class */
export class Image extends DurableObject<Env> {

  image_id: string;
  secret: string;
  filename: string;
  postdata: string;
  called: number;

  /**
   * The constructor is invoked once upon creation of the Durable Object, i.e. the first call to
   *  `DurableObjectStub::get` for a given identifier (no-op constructors can be omitted)
   *
   * @param ctx - The interface for interacting with Durable Object state
   * @param env - The interface to reference bindings declared in wrangler.jsonc
   */
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.image_id = (await ctx.storage.get("image_id") as string) || "";
      this.secret = (await ctx.storage.get("secret") as string) || "";
      this.filename = (await ctx.storage.get("filename") as string) || "";
      this.postdata = (await ctx.storage.get("postdata") as string) || "";
      this.called = (await ctx.storage.get("called") as number) || 0;
    })
  }

  async deleteSelf() {
    await this.ctx.storage.deleteAll();
  }

  async existingObject() {
    return this.postdata != "";

  }

  async write() {
    if (this.postdata == "") {
      // failsafe: don't write if other data hasn't been written
      return;
    }
    await this.ctx.storage.put("image_id", this.image_id);
    await this.ctx.storage.put("secret", this.secret);
    await this.ctx.storage.put("filename", this.filename);
    await this.ctx.storage.put("postdata", this.postdata);
    await this.ctx.storage.put("called", this.called);
  }

  async getAdminToJson() {
    return {
      image_id: this.image_id,
      secret: this.secret,
      filename: this.filename,
      postdata: this.postdata,
      called: this.called,
      public_url: (await this.getPublicUrl()),
    }
  }

  async incCalled() {
    this.called += 1;
    await this.write();
  }

  async generateSecret() {
    this.secret = generateSecret();
  }

  async setFields(image_id: string, filename: string, postdata: string): Promise<void> {
    this.image_id = image_id;
    this.filename = filename;
    this.postdata = postdata;
    await this.write();
  }

  async getPublicUrl() {
    return `https://example.example/${this.image_id}/${this.secret}/${this.filename}`;
  }

  async isValidGet(secret: string, filename: string): Promise<boolean> {
    // if DO is new, not valid
    if (!await this.existingObject()) {
      return false;
    }
    // check to make sure secret and filename match instance values
    if (secret != this.secret || filename != this.filename) {
      return false;
    }
    return true;
  }

  /**
   * The Durable Object exposes an RPC method sayHello which will be invoked when a Durable
   *  Object instance receives a request from a Worker via the same method invocation on the stub
   *
   * @returns The greeting to be sent back to the Worker
   */
  async sayHello(): Promise<string> {
    await this.incCalled();
    return this.called as string;
  }

  __DURABLE_OBJECT_BRAND: never;
}
