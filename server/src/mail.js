import { createHmac, randomUUID } from 'node:crypto';

const encode = value => encodeURIComponent(String(value)).replace(/[!'()*]/g,
  c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);

export function signMail(parameters, secret) {
  const query = Object.keys(parameters).sort().map(key => `${encode(key)}=${encode(parameters[key])}`).join('&');
  const signature = createHmac('sha1', `${secret}&`).update(`POST&%2F&${encode(query)}`).digest('base64');
  return `${query}&Signature=${encode(signature)}`;
}

export function createMailer(config, fetcher = fetch) {
  return {
    async sendCode(address, code) {
      const parameters = { Action: 'SingleSendMail', Version: '2015-11-23', Format: 'JSON',
        AccessKeyId: config.accessKeyID, SignatureMethod: 'HMAC-SHA1', SignatureVersion: '1.0',
        SignatureNonce: randomUUID(), Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
        RegionId: config.region, AccountName: config.sender, AddressType: '1', ReplyToAddress: 'false',
        FromAlias: 'Pocahontas', ToAddress: address, Subject: 'Pocahontas verification code',
        TextBody: `Your Pocahontas verification code is ${code}. It expires in 5 minutes. Do not share this code. If you did not request it, ignore this message.` };
      if (config.securityToken) parameters.SecurityToken = config.securityToken;
      const response = await fetcher(config.endpoint, { method: 'POST', redirect: 'error',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: signMail(parameters, config.accessKeySecret), signal: AbortSignal.timeout(3000) });
      const result = await response.json();
      if (!response.ok || result.Code || !result.RequestId) throw new Error('Mail delivery failed');
    },
  };
}
