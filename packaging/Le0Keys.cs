using System;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Crypto.Digests;
using Org.BouncyCastle.Math;
using Org.BouncyCastle.Math.EC;

public static class Le0Keys
{
    const string Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    public static string NewMnemonic(string[] wordlist)
    {
        if (wordlist == null || wordlist.Length != 2048) throw new Exception("wordlist");
        byte[] ent = new byte[16];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(ent);
        return EntropyToMnemonic(ent, wordlist);
    }

    public static bool IsValid(string mnemonic, string[] wordlist)
    {
        try
        {
            var words = Split(mnemonic);
            if (words.Length != 12) return false;
            int[] idx = new int[12];
            for (int i = 0; i < 12; i++)
            {
                idx[i] = Array.IndexOf(wordlist, words[i]);
                if (idx[i] < 0) return false;
            }
            // 12 * 11 = 132 bits. First 128 entropy, last 4 checksum.
            byte[] ent = new byte[16];
            int acc = 0, bits = 0, ei = 0;
            int checksum = 0;
            for (int w = 0; w < 12; w++)
            {
                acc = (acc << 11) | idx[w];
                bits += 11;
                while (bits >= 8 && ei < 16)
                {
                    bits -= 8;
                    ent[ei++] = (byte)((acc >> bits) & 0xff);
                }
                if (w == 11) checksum = acc & 0xf;
            }
            byte[] hash;
            using (var sha = SHA256.Create()) hash = sha.ComputeHash(ent);
            return (hash[0] >> 4) == checksum;
        }
        catch { return false; }
    }

    public static string AccountXprv(string mnemonic)
    {
        byte[] seed = ToSeed(mnemonic, "");
        byte[] k, c;
        Master(seed, out k, out c);
        int[] path = new int[] { unchecked((int)0x80000054), unchecked((int)0x80000000), unchecked((int)0x80000000) };
        byte[] fp = new byte[] { 0, 0, 0, 0 };
        int depth = 0;
        int index = 0;
        foreach (int i in path)
        {
            byte[] parentFp = Fingerprint(k);
            Child(ref k, ref c, i);
            depth++;
            fp = parentFp;
            index = i;
        }
        return EncodeXprv(k, c, (byte)depth, fp, (uint)index);
    }

    static string EntropyToMnemonic(byte[] ent, string[] wordlist)
    {
        byte[] hash;
        using (var sha = SHA256.Create()) hash = sha.ComputeHash(ent);
        int acc = 0, bits = 0;
        var words = new string[12];
        int wi = 0;
        for (int i = 0; i < ent.Length; i++)
        {
            acc = (acc << 8) | ent[i];
            bits += 8;
            if (i == ent.Length - 1)
            {
                acc = (acc << 4) | (hash[0] >> 4);
                bits += 4;
            }
            while (bits >= 11)
            {
                bits -= 11;
                int idx = (acc >> bits) & 0x7ff;
                words[wi++] = wordlist[idx];
            }
        }
        return string.Join(" ", words);
    }

    public static byte[] ToSeed(string mnemonic, string passphrase)
    {
        var pw = Encoding.UTF8.GetBytes(Normalize(mnemonic));
        var salt = Encoding.UTF8.GetBytes("mnemonic" + (passphrase ?? ""));
        return Pbkdf2(pw, salt, 2048, 64);
    }

    static string Normalize(string s)
    {
        var parts = Split(s);
        return string.Join(" ", parts);
    }

    static string[] Split(string s)
    {
        return s.Trim().ToLowerInvariant().Split(new[] { ' ', '\r', '\n', '\t' }, StringSplitOptions.RemoveEmptyEntries);
    }

    static byte[] Pbkdf2(byte[] password, byte[] salt, int iterations, int bytes)
    {
        using (var hmac = new HMACSHA512(password))
        {
            int hashLen = 64;
            int blocks = (bytes + hashLen - 1) / hashLen;
            byte[] result = new byte[blocks * hashLen];
            for (int i = 1; i <= blocks; i++)
            {
                byte[] block = new byte[salt.Length + 4];
                Buffer.BlockCopy(salt, 0, block, 0, salt.Length);
                block[salt.Length] = (byte)(i >> 24);
                block[salt.Length + 1] = (byte)(i >> 16);
                block[salt.Length + 2] = (byte)(i >> 8);
                block[salt.Length + 3] = (byte)i;
                byte[] u = hmac.ComputeHash(block);
                byte[] t = (byte[])u.Clone();
                for (int j = 1; j < iterations; j++)
                {
                    u = hmac.ComputeHash(u);
                    for (int k = 0; k < t.Length; k++) t[k] ^= u[k];
                }
                Buffer.BlockCopy(t, 0, result, (i - 1) * hashLen, hashLen);
            }
            if (result.Length == bytes) return result;
            byte[] cut = new byte[bytes];
            Buffer.BlockCopy(result, 0, cut, 0, bytes);
            return cut;
        }
    }

    static void Master(byte[] seed, out byte[] k, out byte[] c)
    {
        using (var hmac = new HMACSHA512(Encoding.ASCII.GetBytes("Bitcoin seed")))
        {
            byte[] I = hmac.ComputeHash(seed);
            k = new byte[32];
            c = new byte[32];
            Buffer.BlockCopy(I, 0, k, 0, 32);
            Buffer.BlockCopy(I, 32, c, 0, 32);
        }
    }

    static void Child(ref byte[] k, ref byte[] c, int index)
    {
        uint ui = (uint)index;
        byte[] data = new byte[1 + 32 + 4];
        data[0] = 0;
        Buffer.BlockCopy(k, 0, data, 1, 32);
        data[33] = (byte)(ui >> 24);
        data[34] = (byte)(ui >> 16);
        data[35] = (byte)(ui >> 8);
        data[36] = (byte)ui;
        byte[] I;
        using (var hmac = new HMACSHA512(c)) I = hmac.ComputeHash(data);
        var curve = SecNamedCurves.GetByName("secp256k1");
        var n = curve.N;
        var il = new BigInteger(1, Copy(I, 0, 32));
        var ki = il.Add(new BigInteger(1, k)).Mod(n);
        k = To32(ki);
        c = Copy(I, 32, 32);
    }

    static byte[] Fingerprint(byte[] k)
    {
        byte[] pub = Compressed(k);
        byte[] sha;
        using (var s = SHA256.Create()) sha = s.ComputeHash(pub);
        var rip = new RipeMD160Digest();
        rip.BlockUpdate(sha, 0, sha.Length);
        byte[] hash = new byte[20];
        rip.DoFinal(hash, 0);
        return Copy(hash, 0, 4);
    }

    static byte[] Compressed(byte[] k)
    {
        var x9 = SecNamedCurves.GetByName("secp256k1");
        var d = new BigInteger(1, k);
        Org.BouncyCastle.Math.EC.ECPoint q = x9.G.Multiply(d).Normalize();
        return q.GetEncoded(true);
    }

    static string EncodeXprv(byte[] k, byte[] c, byte depth, byte[] parentFp, uint index)
    {
        byte[] payload = new byte[78];
        payload[0] = 0x04; payload[1] = 0x88; payload[2] = 0xAD; payload[3] = 0xE4;
        payload[4] = depth;
        Buffer.BlockCopy(parentFp, 0, payload, 5, 4);
        payload[9] = (byte)(index >> 24);
        payload[10] = (byte)(index >> 16);
        payload[11] = (byte)(index >> 8);
        payload[12] = (byte)index;
        Buffer.BlockCopy(c, 0, payload, 13, 32);
        payload[45] = 0;
        Buffer.BlockCopy(k, 0, payload, 46, 32);
        byte[] check;
        using (var sha = SHA256.Create())
        {
            check = sha.ComputeHash(sha.ComputeHash(payload));
        }
        byte[] full = new byte[82];
        Buffer.BlockCopy(payload, 0, full, 0, 78);
        Buffer.BlockCopy(check, 0, full, 78, 4);
        return Base58(full);
    }

    static string Base58(byte[] data)
    {
        var num = new BigInteger(1, data);
        var sb = new StringBuilder();
        var b58 = new BigInteger("58");
        var zero = BigInteger.Zero;
        while (num.CompareTo(zero) > 0)
        {
            var rem = num.Mod(b58);
            num = num.Divide(b58);
            sb.Insert(0, Alphabet[(int)rem.IntValue]);
        }
        foreach (byte b in data)
        {
            if (b == 0) sb.Insert(0, '1');
            else break;
        }
        return sb.ToString();
    }

    static byte[] Copy(byte[] src, int offset, int len)
    {
        byte[] d = new byte[len];
        Buffer.BlockCopy(src, offset, d, 0, len);
        return d;
    }

    static byte[] To32(BigInteger v)
    {
        byte[] raw = v.ToByteArrayUnsigned();
        if (raw.Length == 32) return raw;
        byte[] d = new byte[32];
        Buffer.BlockCopy(raw, 0, d, 32 - raw.Length, raw.Length);
        return d;
    }
}
