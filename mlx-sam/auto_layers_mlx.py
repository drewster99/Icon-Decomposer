import os
import sys
import numpy as np
from PIL import Image
import cv2

from mlxformers import MlxSamModel
from transformers import SamProcessor
from transformers.tokenization_utils import BatchEncoding

# -------- config --------
OUTPUT_DIR = "output"
GRID_STEPS = 4            # 4x4 = 16 prompts. Increase for more detail.
MIN_PIXELS = 200          # drop tiny specks
IOU_MERGE_THRESH = 0.8    # merge near-duplicate regions

os.makedirs(OUTPUT_DIR, exist_ok=True)

# -------- helpers --------

def to_uint8(arr):
    if arr.dtype == np.uint8:
        return arr
    if arr.dtype == np.uint16:
        return (arr / 257).astype(np.uint8)
    return np.clip(arr, 0, 255).astype(np.uint8)

def load_full_depth(path):
    """Return (color_full, alpha_full). color_full keeps uint8 or uint16."""
    orig = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if orig is None:
        raise RuntimeError(f"cannot read {path}")

    if orig.ndim == 2:
        color_full = orig
        alpha_full = None
    elif orig.shape[2] == 4:
        color_full = orig[:, :, :3]
        alpha_full = orig[:, :, 3]
    else:
        color_full = orig[:, :, :3]
        alpha_full = None

    return color_full, alpha_full

def run_point(model, processor, image_pil, x, y):
    """
    Ask SAM 'what object is here' at (x,y).
    Returns binary mask bool[H,W] or None if nothing.
    """
    input_points = [[[x, y]]]

    inputs = processor(image_pil, input_points=input_points, return_tensors="np")
    # HF bug workaround
    inputs["input_points"] = inputs["input_points"][None]
    inputs = BatchEncoding(data=dict(inputs), tensor_type="mlx")

    outputs = model(**inputs)

    masks = model.post_process_masks(
        masks=outputs.pred_masks,
        original_sizes=inputs.original_sizes,
        reshaped_input_sizes=inputs.reshaped_input_sizes,
        pad_size=processor.image_processor.pad_size,
        binarize=False,
    )

    # masks[0] is [1,H,W] float logits/probs
    m = np.array(masks[0])
    # squeeze to [H,W]
    while m.ndim > 2:
        m = m[0]
    # threshold at 0.5
    m_bin = m > 0.5

    # reject empty / tiny
    if m_bin.sum() < MIN_PIXELS:
        return None

    return m_bin

def iou(a, b):
    inter = np.logical_and(a, b).sum()
    denom = np.logical_or(a, b).sum()
    if denom == 0:
        return 0.0
    return inter / denom

def dedupe_masks(masks_bool, iou_thresh):
    """
    Greedy dedupe. Keep first mask. Drop any later masks with IoU >= thresh with any kept.
    masks_bool is list of bool[H,W].
    Returns deduped list.
    """
    kept = []
    for m in masks_bool:
        if m is None:
            continue
        dup = False
        for k in kept:
            if iou(m, k) >= iou_thresh:
                dup = True
                break
        if not dup:
            kept.append(m)
    return kept

def export_layers(base, masks_bool, color_full, alpha_full):
    """
    For each mask m_bool (H,W):
    - create 8-bit alpha
    - intersect with original alpha if any
    - cut full-depth pixels
    - write PNG
    - write manifest
    """
    h, w = color_full.shape[:2]
    manifest_path = os.path.join(OUTPUT_DIR, f"{base}_layers.txt")
    with open(manifest_path, "w") as mf:
        mf.write(f"# layer export order for {base}\n")

        # sort by area desc
        areas = [int(m.sum()) for m in masks_bool]
        order = np.argsort([-a for a in areas])

        for idx, oi in enumerate(order):
            m_bool = masks_bool[oi]
            area = areas[oi]

            # build mask8
            mask8 = (m_bool.astype(np.uint8) * 255)

            # respect existing alpha channel
            if alpha_full is not None:
                if alpha_full.dtype != np.uint8:
                    alpha8 = to_uint8(alpha_full)
                    mask8 = cv2.bitwise_and(mask8, alpha8)
                else:
                    mask8 = cv2.bitwise_and(mask8, alpha_full)

            # cut from full depth
            if color_full.dtype == np.uint8:
                cut = cv2.bitwise_and(color_full, color_full, mask=mask8)
            elif color_full.dtype == np.uint16:
                mask16 = (mask8.astype(np.uint16) * 257)
                m_keep = mask16 > 0
                cut = np.zeros_like(color_full, dtype=np.uint16)
                if color_full.ndim == 2:
                    cut[m_keep] = color_full[m_keep]
                else:
                    for c in range(color_full.shape[2]):
                        ch_dst = cut[:, :, c]
                        ch_src = color_full[:, :, c]
                        ch_dst[m_keep] = ch_src[m_keep]
                        cut[:, :, c] = ch_dst
            else:
                tmp8 = to_uint8(color_full)
                cut = cv2.bitwise_and(tmp8, tmp8, mask=mask8)

            out_path = os.path.join(OUTPUT_DIR, f"{base}_layer{idx:02d}.png")
            cv2.imwrite(out_path, cut)
            mf.write(f"{base}_layer{idx:02d}.png area={area}\n")

    print(f"{base}: wrote {len(masks_bool)} layers")

def process_icon(icon_path):
    base = os.path.splitext(os.path.basename(icon_path))[0]

    # load image for the model (PIL, RGB 8-bit)
    image_pil = Image.open(icon_path).convert("RGB")
    w, h = image_pil.size

    # load full depth for export
    color_full, alpha_full = load_full_depth(icon_path)

    # init model/processor once per icon
    model = MlxSamModel.from_pretrained("EduardoPacheco/mlx-sam-vit-base")
    processor = SamProcessor.from_pretrained("EduardoPacheco/mlx-sam-vit-base")

    # grid of prompt points across ~10%..90% of the icon
    xs = np.linspace(w * 0.15, w * 0.85, GRID_STEPS)
    ys = np.linspace(h * 0.15, h * 0.85, GRID_STEPS)

    masks_collected = []
    for yy in ys:
        for xx in xs:
            m_bin = run_point(model, processor, image_pil, float(xx), float(yy))
            if m_bin is not None:
                masks_collected.append(m_bin)

    if len(masks_collected) == 0:
        print(f"{base}: no masks found")
        return

    # dedupe by IoU
    masks_dedup = dedupe_masks(masks_collected, IOU_MERGE_THRESH)

    if len(masks_dedup) == 0:
        print(f"{base}: masks all merged away")
        return

    # export cutouts
    export_layers(base, masks_dedup, color_full, alpha_full)

def main():
    if len(sys.argv) < 2:
        print("usage: python auto_layers_mlx.py path/to/icon.png")
        return

    icon_path = sys.argv[1]
    process_icon(icon_path)

if __name__ == "__main__":
    main()