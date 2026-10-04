# Converts official NAFNet weights (megvii-research/NAFNet, MIT) to Core ML.
import sys, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
import coremltools as ct

class LayerNorm2d(nn.Module):
    def __init__(self, c, eps=1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(c)); self.bias = nn.Parameter(torch.zeros(c)); self.eps = eps
    def forward(self, x):
        mu = x.mean(1, keepdim=True)
        var = (x - mu).pow(2).mean(1, keepdim=True)
        y = (x - mu) / torch.sqrt(var + self.eps)
        return self.weight.view(1, -1, 1, 1) * y + self.bias.view(1, -1, 1, 1)

class SimpleGate(nn.Module):
    def forward(self, x):
        x1, x2 = x.chunk(2, dim=1)
        return x1 * x2

class NAFBlock(nn.Module):
    def __init__(self, c, DW_Expand=2, FFN_Expand=2):
        super().__init__()
        dw = c * DW_Expand
        self.conv1 = nn.Conv2d(c, dw, 1)
        self.conv2 = nn.Conv2d(dw, dw, 3, padding=1, groups=dw)
        self.conv3 = nn.Conv2d(dw // 2, c, 1)
        self.sca = nn.Sequential(nn.AdaptiveAvgPool2d(1), nn.Conv2d(dw // 2, dw // 2, 1))
        self.sg = SimpleGate()
        ffn = FFN_Expand * c
        self.conv4 = nn.Conv2d(c, ffn, 1)
        self.conv5 = nn.Conv2d(ffn // 2, c, 1)
        self.norm1 = LayerNorm2d(c); self.norm2 = LayerNorm2d(c)
        self.beta = nn.Parameter(torch.zeros((1, c, 1, 1))); self.gamma = nn.Parameter(torch.zeros((1, c, 1, 1)))
    def forward(self, inp):
        x = self.norm1(inp)
        x = self.conv2(self.conv1(x))
        x = self.sg(x)
        # global average pool written as mean (converts cleanly for any input size)
        x = x * self.sca[1](x.mean(dim=(2, 3), keepdim=True))
        x = self.conv3(x)
        y = inp + x * self.beta
        x = self.conv5(self.sg(self.conv4(self.norm2(y))))
        return y + x * self.gamma

class NAFNet(nn.Module):
    def __init__(self, img_channel=3, width=16, middle_blk_num=1, enc_blk_nums=[], dec_blk_nums=[]):
        super().__init__()
        self.intro = nn.Conv2d(img_channel, width, 3, padding=1)
        self.ending = nn.Conv2d(width, img_channel, 3, padding=1)
        self.encoders = nn.ModuleList(); self.decoders = nn.ModuleList(); self.ups = nn.ModuleList(); self.downs = nn.ModuleList()
        chan = width
        for num in enc_blk_nums:
            self.encoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(num)]))
            self.downs.append(nn.Conv2d(chan, 2 * chan, 2, 2)); chan *= 2
        self.middle_blks = nn.Sequential(*[NAFBlock(chan) for _ in range(middle_blk_num)])
        for num in dec_blk_nums:
            self.ups.append(nn.Sequential(nn.Conv2d(chan, chan * 2, 1, bias=False), nn.PixelShuffle(2))); chan //= 2
            self.decoders.append(nn.Sequential(*[NAFBlock(chan) for _ in range(num)]))
    def forward(self, inp):
        x = self.intro(inp)
        encs = []
        for enc, down in zip(self.encoders, self.downs):
            x = enc(x); encs.append(x); x = down(x)
        x = self.middle_blks(x)
        for dec, up, skip in zip(self.decoders, self.ups, encs[::-1]):
            x = dec(up(x) + skip)
        return self.ending(x) + inp

CFG = {
    "sidd": dict(width=32, enc_blk_nums=[2, 2, 4, 8], middle_blk_num=12, dec_blk_nums=[2, 2, 2, 2]),
    "gopro": dict(width=32, enc_blk_nums=[1, 1, 1, 28], middle_blk_num=1, dec_blk_nums=[1, 1, 1, 1]),
}

def main(kind, weights, out, tile):
    net = NAFNet(**CFG[kind])
    sd = torch.load(weights, map_location="cpu")
    sd = sd.get("params", sd)
    net.load_state_dict(sd, strict=True)
    net.eval()
    ex = torch.rand(1, 3, tile, tile)
    with torch.no_grad():
        traced = torch.jit.trace(net, ex)
        ref = net(ex).numpy()
    mlm = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=ex.shape)], outputs=[ct.TensorType(name="output")],
                     convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
    mlm.short_description = f"NAFNet {kind} width32 (megvii-research/NAFNet, MIT). Input/output RGB 0..1, {tile}x{tile}."
    mlm.author = "Converted for ImageCrat"
    mlm.license = "MIT"
    got = mlm.predict({"input": ex.numpy()})["output"]
    print(kind, "max abs diff fp16 vs torch:", float(np.abs(got - ref).max()), "mean", float(np.abs(got - ref).mean()))
    mlm.save(out)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 512)
