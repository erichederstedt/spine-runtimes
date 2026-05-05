/****************************************************************************
 * Spine Runtimes License Agreement
 * Last updated April 5, 2025. Replaces all prior versions.
 *
 * Copyright (c) 2013-2025, Esoteric Software LLC
 *
 * Integration of the Spine Runtimes into software or otherwise creating
 * derivative works of the Spine Runtimes is permitted under the terms and
 * conditions of Section 2 of the Spine Editor License Agreement:
 * http://esotericsoftware.com/spine-editor-license
 *
 * Otherwise, it is permitted to integrate the Spine Runtimes into software
 * or otherwise create derivative works of the Spine Runtimes (collectively,
 * "Products"), provided that each user of the Products must obtain their own
 * Spine Editor license and redistribution of the Products in any form must
 * include this license and copyright notice.
 *
 * THE SPINE RUNTIMES ARE PROVIDED BY ESOTERIC SOFTWARE LLC "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL ESOTERIC SOFTWARE LLC BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES,
 * BUSINESS INTERRUPTION, OR LOSS OF USE, DATA, OR PROFITS) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THE SPINE RUNTIMES, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*****************************************************************************/

package spine.heaps;

import h2d.BlendMode;
import h2d.Tile;
import h3d.mat.Data.Compare;
import h3d.mat.Data.Face;
import h3d.mat.Material;
import h3d.mat.Pass;
import h3d.scene.Mesh;
import h3d.scene.Object;
import h3d.shader.VertexColorAlpha;
import spine.Color;

/** A Heaps mesh that renders one batch of consecutive same-texture same-blend-mode Spine slots. */
class SkeletonMesh extends Mesh {
	private static inline var SLOT_DEPTH_STEP = 0.0001;

	private var geometry:SpineMeshPrimitive;
	private var heapsMaterial:Material;
	private var premultiplyAlphaShader:PremultiplyAlphaShader;
	private var batchHasGeometry = false;

	public function new(?parent:Object) {
		geometry = new SpineMeshPrimitive();
		heapsMaterial = h3d.mat.MaterialSetup.current.createMaterial();
		heapsMaterial.mainPass.enableLights = false;
		heapsMaterial.mainPass.depthWrite = false;
		heapsMaterial.mainPass.culling = Face.None;
		heapsMaterial.mainPass.layer = 0;
		heapsMaterial.mainPass.addShader(new VertexColorAlpha());
		premultiplyAlphaShader = new PremultiplyAlphaShader();
		super(geometry, heapsMaterial, parent);
	}

	public function setOrder(order:Int):Void {
		z = order >= 0 ? order * SLOT_DEPTH_STEP : 0.0;
	}

	/** Prepare this mesh for a new batch: set material state and reset geometry. */
	public function resetBatch(tile:Tile, slotBlendMode:spine.BlendMode, premultipliedAlpha:Bool, blendModeOverride:Null<BlendMode>):Void {
		heapsMaterial.texture = tile.getTexture();
		applyPremultiplyAlpha(slotBlendMode, premultipliedAlpha, blendModeOverride);
		applyBlendMode(slotBlendMode, premultipliedAlpha, blendModeOverride);
		geometry.reset();
		batchHasGeometry = false;
	}

	/** Accumulate one slot's geometry into the current batch. */
	public function addSlot(vertices:Array<Float>, uvs:Array<Float>, indices:Array<Int>, color:Color, premultipliedAlpha:Bool):Void {
		var r = color.r, g = color.g, b = color.b;
		final a = color.a;
		// Match the original material-colour behaviour: PMA blend needs pre-multiplied RGB.
		if (premultipliedAlpha) {
			r *= a;
			g *= a;
			b *= a;
		}
		geometry.addGeometry(vertices, uvs, indices, r, g, b, a);
		batchHasGeometry = true;
	}

	/** Upload accumulated geometry and make the mesh visible. */
	public function flushBatch():Void {
		if (batchHasGeometry)
			geometry.flush();
		visible = batchHasGeometry;
	}

	public function hide():Void {
		visible = false;
	}

	public function dispose():Void {
		remove();
		geometry.dispose();
	}

	private function applyPremultiplyAlpha(slotBlendMode:spine.BlendMode, premultipliedAlpha:Bool, blendModeOverride:Null<BlendMode>):Void {
		final shouldPremultiply = blendModeOverride == null && slotBlendMode == spine.BlendMode.multiply && !premultipliedAlpha;
		final hasShader = heapsMaterial.mainPass.getShader(PremultiplyAlphaShader) != null;
		if (shouldPremultiply && !hasShader)
			heapsMaterial.mainPass.addShader(premultiplyAlphaShader);
		else if (!shouldPremultiply && hasShader)
			heapsMaterial.mainPass.removeShader(premultiplyAlphaShader);
	}

	private function applyBlendMode(slotBlendMode:spine.BlendMode, premultipliedAlpha:Bool, blendModeOverride:Null<BlendMode>):Void {
		final pass = heapsMaterial.mainPass;
		pass.depth(false, Compare.Always);
		pass.setPassName("alpha");
		if (blendModeOverride != null) {
			pass.setBlendMode(blendModeOverride);
			return;
		}
		if (premultipliedAlpha) {
			setPremultipliedBlendMode(pass, slotBlendMode);
			return;
		}
		pass.setBlendMode(toBlendMode(slotBlendMode));
	}

	private static function setPremultipliedBlendMode(pass:Pass, slotBlendMode:spine.BlendMode):Void {
		switch (slotBlendMode) {
			case normal:
				pass.setBlendMode(BlendMode.AlphaAdd);
			case additive:
				pass.blend(One, One);
			case multiply:
				pass.setBlendMode(BlendMode.AlphaMultiply);
			case screen:
				pass.setBlendMode(BlendMode.Screen);
			default:
				pass.setBlendMode(BlendMode.AlphaAdd);
		}
	}

	public static function toBlendMode(spineBlendMode:spine.BlendMode):BlendMode {
		return switch spineBlendMode {
			case normal: BlendMode.Alpha;
			case additive: BlendMode.Add;
			case multiply: BlendMode.AlphaMultiply;
			case screen: BlendMode.Screen;
			default: BlendMode.Alpha;
		}
	}
}

private class PremultiplyAlphaShader extends hxsl.Shader {
	static var SRC = {
		var pixelColor:Vec4;
		function fragment() {
			pixelColor.rgb *= pixelColor.a;
		}
	}
}

/** Primitive that accumulates geometry from multiple slots into a single vertex/index buffer.
	Vertex layout: position(xyz) + uv(xy) + colour(rgba) = 9 floats. **/
private class SpineMeshPrimitive extends h3d.prim.DynamicPrimitive {
	static inline var STRIDE = 9;

	var vertCount = 0;
	var idxCount = 0;

	public function new() {
		super(hxd.BufferFormat.POS3D_UV.append("color", hxd.BufferFormat.InputFormat.DVec4));
	}

	/** Clear write-heads for a new batch. */
	public function reset():Void {
		vertCount = 0;
		idxCount = 0;
		bounds.empty();
	}

	/** Append one slot's geometry. Index values are offset by the current vertex count. */
	public function addGeometry(vertices:Array<Float>, uvs:Array<Float>, indices:Array<Int>, r:Float, g:Float, b:Float, a:Float):Void {
		final vc = vertices.length >> 1;
		if (vc == 0 || indices.length == 0)
			return;
		final buf = getBuffer(vertCount + vc);
		for (i in 0...vc) {
			final src = i * 2;
			final dst = (vertCount + i) * STRIDE;
			final x = vertices[src];
			final y = vertices[src + 1];
			buf[dst] = x;
			buf[dst + 1] = y;
			buf[dst + 2] = 0.0;
			buf[dst + 3] = src < uvs.length ? uvs[src] : 0.0;
			buf[dst + 4] = src + 1 < uvs.length ? uvs[src + 1] : 0.0;
			buf[dst + 5] = r;
			buf[dst + 6] = g;
			buf[dst + 7] = b;
			buf[dst + 8] = a;
			bounds.addPos(x, y, 0.0);
		}
		final iBuf = getIndexes(idxCount + indices.length);
		for (i in 0...indices.length)
			iBuf[idxCount + i] = indices[i] + vertCount;
		vertCount += vc;
		idxCount += indices.length;
	}
}
