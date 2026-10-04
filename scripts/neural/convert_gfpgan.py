# Converts official GFPGAN v1.4 weights (TencentARC/GFPGAN) to Core ML.
# Architecture re-implemented from gfpganv1_clean_arch.py / stylegan2_clean_arch.py (same parameter names so the
# official state dict loads strictly). Modulated convs use the equivalent "non-fused" formulation
# (scale input by style, static conv, demodulate) so Core ML sees constant conv weights.
import sys, math, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
import coremltools as ct

class NormStyleCode(nn.Module):
    def forward(self, x):
        return x * torch.rsqrt(torch.mean(x ** 2, dim=1, keepdim=True) + 1e-8)

class ModulatedConv2d(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size, num_style_feat, demodulate=True, sample_mode=None, eps=1e-8):
        super().__init__()
        self.in_channels, self.out_channels, self.kernel_size = in_channels, out_channels, kernel_size
        self.demodulate, self.sample_mode, self.eps = demodulate, sample_mode, eps
        self.modulation = nn.Linear(num_style_feat, in_channels, bias=True)
        self.weight = nn.Parameter(torch.randn(1, out_channels, in_channels, kernel_size, kernel_size) / math.sqrt(in_channels * kernel_size ** 2))
        self.padding = kernel_size // 2

    def forward(self, x, style):
        b, c, h, w = x.shape
        s = self.modulation(style)                      # (b, c_in)
        W = self.weight[0]                               # (c_out, c_in, k, k)
        if self.sample_mode == 'upsample':
            x = F.interpolate(x, scale_factor=2, mode='bilinear', align_corners=False)
        elif self.sample_mode == 'downsample':
            x = F.interpolate(x, scale_factor=0.5, mode='bilinear', align_corners=False)
        if self.demodulate:
            # demodulation is invariant to the scale of s: normalise it so fp16 activations stay bounded
            s = s * torch.rsqrt(torch.mean(s * s, dim=1, keepdim=True) + 1e-8)
        out = F.conv2d(x * s.view(b, c, 1, 1), W, padding=self.padding)
        if self.demodulate:
            w2 = W.pow(2).sum([2, 3])                    # (c_out, c_in)
            demod = torch.rsqrt(torch.matmul(s.pow(2), w2.t()) + self.eps)   # (b, c_out)
            out = out * demod.view(b, self.out_channels, 1, 1)
        return out

class StyleConv(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size, num_style_feat, demodulate=True, sample_mode=None):
        super().__init__()
        self.modulated_conv = ModulatedConv2d(in_channels, out_channels, kernel_size, num_style_feat, demodulate=demodulate, sample_mode=sample_mode)
        self.weight = nn.Parameter(torch.zeros(1))
        self.bias = nn.Parameter(torch.zeros(1, out_channels, 1, 1))
        self.activate = nn.LeakyReLU(negative_slope=0.2)
    def forward(self, x, style, noise):
        out = self.modulated_conv(x, style) * 2 ** 0.5
        out = out + self.weight * noise
        return self.activate(out + self.bias)

class ToRGB(nn.Module):
    def __init__(self, in_channels, num_style_feat, upsample=True):
        super().__init__()
        self.upsample = upsample
        self.modulated_conv = ModulatedConv2d(in_channels, 3, kernel_size=1, num_style_feat=num_style_feat, demodulate=False)
        self.bias = nn.Parameter(torch.zeros(1, 3, 1, 1))
    def forward(self, x, style, skip=None):
        out = self.modulated_conv(x, style) + self.bias
        if skip is not None:
            if self.upsample:
                skip = F.interpolate(skip, scale_factor=2, mode='bilinear', align_corners=False)
            out = out + skip
        return out

class ConstantInput(nn.Module):
    def __init__(self, num_channel, size):
        super().__init__()
        self.weight = nn.Parameter(torch.randn(1, num_channel, size, size))
    def forward(self, batch):
        return self.weight

class StyleGAN2GeneratorCSFT(nn.Module):
    def __init__(self, out_size, num_style_feat=512, num_mlp=8, channel_multiplier=2, narrow=1, sft_half=False):
        super().__init__()
        self.num_style_feat = num_style_feat
        layers = [NormStyleCode()]
        for _ in range(num_mlp):
            layers += [nn.Linear(num_style_feat, num_style_feat, bias=True), nn.LeakyReLU(negative_slope=0.2)]
        self.style_mlp = nn.Sequential(*layers)
        ch = {'4': int(512 * narrow), '8': int(512 * narrow), '16': int(512 * narrow), '32': int(512 * narrow),
              '64': int(256 * channel_multiplier * narrow), '128': int(128 * channel_multiplier * narrow),
              '256': int(64 * channel_multiplier * narrow), '512': int(32 * channel_multiplier * narrow),
              '1024': int(16 * channel_multiplier * narrow)}
        self.channels = ch
        self.constant_input = ConstantInput(ch['4'], size=4)
        self.style_conv1 = StyleConv(ch['4'], ch['4'], 3, num_style_feat)
        self.to_rgb1 = ToRGB(ch['4'], num_style_feat, upsample=False)
        self.log_size = int(math.log(out_size, 2))
        self.num_layers = (self.log_size - 2) * 2 + 1
        self.num_latent = self.log_size * 2 - 2
        self.style_convs = nn.ModuleList(); self.to_rgbs = nn.ModuleList(); self.noises = nn.Module()
        inc = ch['4']
        for li in range(self.num_layers):
            r = 2 ** ((li + 5) // 2)
            self.noises.register_buffer(f'noise{li}', torch.randn(1, 1, r, r))
        for i in range(3, self.log_size + 1):
            outc = ch[f'{2 ** i}']
            self.style_convs.append(StyleConv(inc, outc, 3, num_style_feat, sample_mode='upsample'))
            self.style_convs.append(StyleConv(outc, outc, 3, num_style_feat))
            self.to_rgbs.append(ToRGB(outc, num_style_feat, upsample=True))
            inc = outc
        self.sft_half = sft_half

    def forward(self, latent, conditions):
        noise = [getattr(self.noises, f'noise{i}') for i in range(self.num_layers)]
        out = self.constant_input(1)
        out = self.style_conv1(out, latent[:, 0], noise[0])
        skip = self.to_rgb1(out, latent[:, 1])
        i = 1
        for conv1, conv2, n1, n2, to_rgb in zip(self.style_convs[::2], self.style_convs[1::2], noise[1::2], noise[2::2], self.to_rgbs):
            out = conv1(out, latent[:, i], n1)
            if i < len(conditions):
                if self.sft_half:
                    half = int(out.size(1) // 2)
                    out_same, out_sft = out[:, :half], out[:, half:]
                    out_sft = out_sft * conditions[i - 1] + conditions[i]
                    out = torch.cat([out_same, out_sft], dim=1)
                else:
                    out = out * conditions[i - 1] + conditions[i]
            out = conv2(out, latent[:, i + 1], n2)
            skip = to_rgb(out, latent[:, i + 2], skip)
            i += 2
        return skip

class ResBlock(nn.Module):
    def __init__(self, in_channels, out_channels, mode='down'):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, in_channels, 3, 1, 1)
        self.conv2 = nn.Conv2d(in_channels, out_channels, 3, 1, 1)
        self.skip = nn.Conv2d(in_channels, out_channels, 1, bias=False)
        self.scale_factor = 0.5 if mode == 'down' else 2
    def forward(self, x):
        out = F.leaky_relu(self.conv1(x), negative_slope=0.2)
        out = F.interpolate(out, scale_factor=self.scale_factor, mode='bilinear', align_corners=False)
        out = F.leaky_relu(self.conv2(out), negative_slope=0.2)
        x = F.interpolate(x, scale_factor=self.scale_factor, mode='bilinear', align_corners=False)
        return out + self.skip(x)

class GFPGANv1Clean(nn.Module):
    def __init__(self, out_size=512, num_style_feat=512, channel_multiplier=2, num_mlp=8, different_w=True, narrow=1, sft_half=True):
        super().__init__()
        self.different_w = different_w
        self.num_style_feat = num_style_feat
        un = narrow * 0.5
        ch = {'4': int(512 * un), '8': int(512 * un), '16': int(512 * un), '32': int(512 * un),
              '64': int(256 * channel_multiplier * un), '128': int(128 * channel_multiplier * un),
              '256': int(64 * channel_multiplier * un), '512': int(32 * channel_multiplier * un),
              '1024': int(16 * channel_multiplier * un)}
        self.log_size = int(math.log(out_size, 2))
        first = 2 ** self.log_size
        self.conv_body_first = nn.Conv2d(3, ch[f'{first}'], 1)
        inc = ch[f'{first}']
        self.conv_body_down = nn.ModuleList()
        for i in range(self.log_size, 2, -1):
            outc = ch[f'{2 ** (i - 1)}']
            self.conv_body_down.append(ResBlock(inc, outc, 'down')); inc = outc
        self.final_conv = nn.Conv2d(inc, ch['4'], 3, 1, 1)
        inc = ch['4']
        self.conv_body_up = nn.ModuleList()
        for i in range(3, self.log_size + 1):
            outc = ch[f'{2 ** i}']
            self.conv_body_up.append(ResBlock(inc, outc, 'up')); inc = outc
        self.toRGB = nn.ModuleList([nn.Conv2d(ch[f'{2 ** i}'], 3, 1) for i in range(3, self.log_size + 1)])
        lin_out = (int(math.log(out_size, 2)) * 2 - 2) * num_style_feat if different_w else num_style_feat
        self.final_linear = nn.Linear(ch['4'] * 4 * 4, lin_out)
        self.stylegan_decoder = StyleGAN2GeneratorCSFT(out_size, num_style_feat, num_mlp, channel_multiplier, narrow, sft_half)
        self.condition_scale = nn.ModuleList(); self.condition_shift = nn.ModuleList()
        for i in range(3, self.log_size + 1):
            outc = ch[f'{2 ** i}']
            sft = outc if sft_half else outc * 2
            self.condition_scale.append(nn.Sequential(nn.Conv2d(outc, outc, 3, 1, 1), nn.LeakyReLU(0.2), nn.Conv2d(outc, sft, 3, 1, 1)))
            self.condition_shift.append(nn.Sequential(nn.Conv2d(outc, outc, 3, 1, 1), nn.LeakyReLU(0.2), nn.Conv2d(outc, sft, 3, 1, 1)))

    def forward(self, x):
        conditions, skips = [], []
        feat = F.leaky_relu(self.conv_body_first(x), negative_slope=0.2)
        for i in range(self.log_size - 2):
            feat = self.conv_body_down[i](feat); skips.insert(0, feat)
        feat = F.leaky_relu(self.final_conv(feat), negative_slope=0.2)
        style = self.final_linear(feat.reshape(1, -1)).reshape(1, -1, self.num_style_feat)
        for i in range(self.log_size - 2):
            feat = feat + skips[i]
            feat = self.conv_body_up[i](feat)
            conditions.append(self.condition_scale[i](feat))
            conditions.append(self.condition_shift[i](feat))
        return self.stylegan_decoder(style, conditions)

def main(weights, out, precision):
    net = GFPGANv1Clean()
    sd = torch.load(weights, map_location="cpu")
    sd = sd.get("params_ema", sd.get("params", sd))
    missing = net.load_state_dict(sd, strict=True)
    print("loaded", missing)
    net.eval()
    ex = torch.rand(1, 3, 512, 512) * 2 - 1
    with torch.no_grad():
        traced = torch.jit.trace(net, ex)
        ref = net(ex).numpy()
    prec = ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32
    mlm = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=ex.shape)], outputs=[ct.TensorType(name="output")],
                     convert_to="mlprogram", compute_precision=prec, minimum_deployment_target=ct.target.macOS15)
    mlm.short_description = "GFPGAN v1.4 face restoration (TencentARC). Input: aligned 512x512 RGB face in [-1,1]; output same range."
    mlm.author = "Converted for ImageCrat"
    mlm.license = "GFPGAN: Apache-2.0; StyleGAN2 components: NVIDIA Source Code License (non-commercial)"
    got = mlm.predict({"input": ex.numpy()})["output"]
    print("max abs diff vs torch:", float(np.abs(got - ref).max()), "mean", float(np.abs(got - ref).mean()))
    mlm.save(out)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "fp16")
