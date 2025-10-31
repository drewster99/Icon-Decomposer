import os
import sys
import numpy as np
from PIL import Image
from mlxformers import MlxSamModel
from transformers import SamProcessor
from transformers.tokenization_utils import BatchEncoding

OUTPUT_DIR = "output"

def save_mask_anyshape(mask_tensor, out_path):
    # mask_tensor is expected [1,H,W] float or [H,W] float
    m = np.array(mask_tensor)
    print("  save_mask_anyshape: raw mask np.shape =", m.shape, "dtype =", m.dtype)

    # squeeze batch/channel dims
    while m.ndim > 2:
        m = m[0]
    # now m should be [H,W]

    # if it's logits or probs float -> threshold
    if m.dtype != np.uint8:
        m_bin = (m > 0.5).astype(np.uint8) * 255
    else:
        # already 0/255?
        m_bin = m

    img = Image.fromarray(m_bin, mode="L")
    img.save(out_path)
    print("  wrote", out_path)

def main():
    if len(sys.argv) < 2:
        print("usage: python point_debug.py path/to/icon.png")
        return

    icon_path = sys.argv[1]
    print("icon_path =", icon_path)
    if not os.path.exists(icon_path):
        print("ERROR: file not found")
        return

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # load local image
    raw_image = Image.open(icon_path).convert("RGB")
    w, h = raw_image.size
    print("image size =", w, "x", h)

    # pick a point near the center so we actually hit content
    cx = w * 0.5
    cy = h * 0.5
    input_points = [[[cx, cy]]]
    print("using point =", input_points)

    print("loading model ...")
    model = MlxSamModel.from_pretrained("EduardoPacheco/mlx-sam-vit-base")
    processor = SamProcessor.from_pretrained("EduardoPacheco/mlx-sam-vit-base")
    print("model loaded")

    print("building inputs ...")
    inputs = processor(raw_image, input_points=input_points, return_tensors="np")
    # HF bug workaround from your sample
    inputs["input_points"] = inputs["input_points"][None]
    inputs = BatchEncoding(data=dict(inputs), tensor_type="mlx")

    print("running model ...")
    outputs = model(**inputs)

    # postprocess to original resolution
    print("post-process ...")
    masks = model.post_process_masks(
        masks=outputs.pred_masks,
        original_sizes=inputs.original_sizes,
        reshaped_input_sizes=inputs.reshaped_input_sizes,
        pad_size=processor.image_processor.pad_size,
        binarize=False,
    )
    scores = outputs.iou_scores

    # debug prints
    print("masks type =", type(masks))
    print("len(masks) =", len(masks) if hasattr(masks, "__len__") else "n/a")
    if hasattr(masks, "__len__") and len(masks) > 0:
        print("masks[0] type =", type(masks[0]))
        try:
            print("masks[0] shape guess =", np.array(masks[0]).shape)
        except Exception as e:
            print("could not inspect masks[0]:", e)

    print("scores shape =", np.array(scores).shape)

    # write mask[0] if it exists
    if hasattr(masks, "__len__") and len(masks) > 0:
        out_path = os.path.join(OUTPUT_DIR, "mask0.png")
        save_mask_anyshape(masks[0], out_path)
    else:
        print("no masks returned, nothing to save")

    print("done.")

if __name__ == "__main__":
    main()