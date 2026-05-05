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
import h3d.mat.Material;
import h3d.scene.Object;
import h3d.scene.RenderContext;
import spine.Bone;
import spine.Color;
import spine.Physics;
import spine.Rectangle;
import spine.Skeleton;
import spine.SkeletonClipping;
import spine.SkeletonData;
import spine.TextureRegion;
import spine.animation.AnimationState;
import spine.animation.AnimationStateData;
import spine.atlas.TextureAtlasRegion;
import spine.attachments.Attachment;
import spine.attachments.ClippingAttachment;
import spine.attachments.MeshAttachment;
import spine.attachments.RegionAttachment;

/** A Heaps scene object that draws a Spine skeleton. */
class SkeletonRenderer extends Object {
	private static var QUAD_INDICES:Array<Int> = [0, 1, 2, 2, 3, 0];

	public static var clipper(default, never):SkeletonClipping = new SkeletonClipping();

	public final skeletonData:SkeletonData;
	public final skeleton:Skeleton;
	public final stateData:AnimationStateData;
	public final state:AnimationState;

	public var blendModeOverride(default, null):Null<BlendMode> = null;

	public var beforeUpdateWorldTransforms:SkeletonRenderer->Void = function(_) {};
	public var afterUpdateWorldTransforms:SkeletonRenderer->Void = function(_) {};

	// Pool of batch meshes, reused across frames.
	private var batches:Array<SkeletonMesh> = [];
	private var activeBatchCount = 0;

	/** Creates a renderer for the specified skeleton data. */
	public function new(skeletonData:SkeletonData, animationStateData:AnimationStateData = null, ?parent:Object) {
		super(parent);
		Bone.yDown = false;
		this.skeletonData = skeletonData;
		this.skeleton = new Skeleton(skeletonData);
		this.skeleton.setToSetupPose();
		this.skeleton.updateWorldTransform(Physics.update);
		this.stateData = animationStateData != null ? animationStateData : new AnimationStateData(skeletonData);
		this.state = new AnimationState(this.stateData);
		refresh();
	}

	/** Advances animation time and rebuilds slot meshes. */
	public function update(time:Float):Void {
		state.update(time);
		state.apply(skeleton);
		beforeUpdateWorldTransforms(this);
		skeleton.update(time);
		skeleton.updateWorldTransform(Physics.update);
		afterUpdateWorldTransforms(this);
	}

	override function emit(ctx:RenderContext) {
		refresh();
	}

	/** Synchronizes slot meshes without advancing animation time. */
	public function refresh():Void {
		syncSlots();
	}

	/** Sets the skeleton color multiplier used for rendering. */
	public function setColor(r:Float, g:Float, b:Float, a:Float):Void {
		skeleton.color.set(r, g, b, a);
		syncSlots();
	}

	/** Overrides the blend mode used by every rendered slot. */
	public function setBlendModeOverride(blendMode:Null<BlendMode>):Void {
		blendModeOverride = blendMode;
		syncSlots();
	}

	/** Returns the current skeleton bounds. */
	public function getSkeletonBounds(?clip:Bool = true):Rectangle {
		return skeleton.getBounds(clip ? new SkeletonClipping() : null);
	}

	/** Releases all slot meshes and removes the root object from the scene. */
	public function dispose():Void {
		state.clearListeners();
		for (batch in batches)
			batch.dispose();
		batches = [];
		remove();
	}

	/** Returns materials for all active batch meshes, bypassing the O(n²) recursive
		scene-graph traversal that Object.getMaterials() would otherwise perform. **/
	override public function getMaterials(?a:Array<Material>, recursive = true):Array<Material> {
		if (a == null)
			a = [];
		for (i in 0...activeBatchCount)
			a.push(batches[i].material);
		return a;
	}

	override public function clone(?o:Object):Object {
		final m:SkeletonRenderer = if (o != null) cast o else new SkeletonRenderer(skeletonData, stateData, parent);
		return cast m;
	}

	private function syncSlots():Void {
		final clipper = SkeletonRenderer.clipper;
		clipper.clipEnd();

		activeBatchCount = 0;
		var batchMesh:SkeletonMesh = null;
		var batchTexture:h3d.mat.Texture = null;
		var batchBlend:spine.BlendMode = cast -1; // invalid sentinel
		var batchPma = false;

		for (slot in skeleton.drawOrder) {
			if (slot == null || !slot.bone.active) {
				if (slot != null)
					clipper.clipEndWithSlot(slot);
				continue;
			}

			if (slot.attachment == null) {
				clipper.clipEndWithSlot(slot);
				continue;
			}

			if (Std.isOfType(slot.attachment, ClippingAttachment)) {
				clipper.clipStart(slot, cast slot.attachment);
				continue;
			}

			final renderData = resolveRenderData(slot, slot.attachment, clipper);
			if (renderData == null || renderData.indices.length == 0) {
				clipper.clipEndWithSlot(slot);
				continue;
			}

			// Open a new batch when texture or blend settings change.
			final tex = renderData.texture.getTexture();
			if (batchMesh == null
				|| tex != batchTexture
				|| renderData.blendMode != batchBlend
				|| renderData.premultipliedAlpha != batchPma) {
				batchMesh?.flushBatch();
				batchMesh = ensureBatch(activeBatchCount);
				batchMesh.resetBatch(renderData.texture, renderData.blendMode, renderData.premultipliedAlpha, blendModeOverride);
				batchMesh.setOrder(activeBatchCount);
				activeBatchCount++;
				batchTexture = tex;
				batchBlend = renderData.blendMode;
				batchPma = renderData.premultipliedAlpha;
			}

			batchMesh.addSlot(renderData.vertices, renderData.uvs, renderData.indices, renderData.color, renderData.premultipliedAlpha);
			clipper.clipEndWithSlot(slot);
		}

		batchMesh?.flushBatch();

		// Hide unused batches from previous frame.
		for (i in activeBatchCount...batches.length)
			batches[i].hide();

		clipper.clipEnd();
	}

	private function ensureBatch(index:Int):SkeletonMesh {
		if (index < batches.length)
			return batches[index];
		final mesh = new SkeletonMesh(this);
		batches.push(mesh);
		return mesh;
	}

	private function resolveRenderData(slot:spine.Slot, attachment:Attachment, clipper:SkeletonClipping):Null<SkeletonRenderData> {
		if (Std.isOfType(attachment, RegionAttachment))
			return buildRegionRenderData(slot, cast attachment, clipper);
		if (Std.isOfType(attachment, MeshAttachment))
			return buildMeshRenderData(slot, cast attachment, clipper);
		return null;
	}

	private function buildRegionRenderData(slot:spine.Slot, regionAttachment:RegionAttachment, clipper:SkeletonClipping):SkeletonRenderData {
		var worldVertices = new Array<Float>();
		worldVertices.resize(8);
		regionAttachment.computeWorldVertices(slot, worldVertices, 0, 2);
		var indices = QUAD_INDICES;
		var uvs = regionAttachment.uvs;
		if (clipper.isClipping()) {
			clipper.clipTriangles(worldVertices, indices, indices.length, uvs);
			worldVertices = clipper.clippedVertices;
			indices = clipper.clippedTriangles;
			uvs = clipper.clippedUvs;
		}
		return {
			texture: resolveAttachmentTile(regionAttachment.region),
			vertices: worldVertices,
			uvs: uvs,
			indices: indices,
			blendMode: slot.data.blendMode,
			premultipliedAlpha: resolvePremultipliedAlpha(regionAttachment.region),
			color: multiplyColor(skeleton.color, slot.color, regionAttachment.color)
		};
	}

	private function buildMeshRenderData(slot:spine.Slot, meshAttachment:MeshAttachment, clipper:SkeletonClipping):SkeletonRenderData {
		final verticesLength = meshAttachment.worldVerticesLength;
		var worldVertices = new Array<Float>();
		worldVertices.resize(verticesLength);
		meshAttachment.computeWorldVertices(slot, 0, verticesLength, worldVertices, 0, 2);
		var indices = meshAttachment.triangles;
		var uvs = meshAttachment.uvs;
		if (clipper.isClipping()) {
			clipper.clipTriangles(worldVertices, indices, indices.length, uvs);
			worldVertices = clipper.clippedVertices;
			indices = clipper.clippedTriangles;
			uvs = clipper.clippedUvs;
		}
		return {
			texture: resolveAttachmentTile(meshAttachment.region),
			vertices: worldVertices,
			uvs: uvs,
			indices: indices,
			blendMode: slot.data.blendMode,
			premultipliedAlpha: resolvePremultipliedAlpha(meshAttachment.region),
			color: multiplyColor(skeleton.color, slot.color, meshAttachment.color)
		};
	}

	private function resolveAttachmentTile(region:TextureRegion):Tile {
		if (region == null)
			throw new spine.SpineException("Attachment is missing a texture region.");
		if (Std.isOfType(region.texture, Tile))
			return cast region.texture;
		if (Std.isOfType(region, TextureAtlasRegion)) {
			final atlasRegion:TextureAtlasRegion = cast region;
			if (atlasRegion.page != null && Std.isOfType(atlasRegion.page.texture, Tile))
				return cast atlasRegion.page.texture;
		}
		throw new spine.SpineException("Attachment region does not contain a Heaps tile.");
	}

	private static function resolvePremultipliedAlpha(region:TextureRegion):Bool {
		if (Std.isOfType(region, TextureAtlasRegion)) {
			final atlasRegion:TextureAtlasRegion = cast region;
			return atlasRegion.page != null && atlasRegion.page.pma;
		}
		return false;
	}

	private static function multiplyColor(skeletonColor:Color, slotColor:Color, attachmentColor:Color):Color {
		return new Color(skeletonColor.r * slotColor.r * attachmentColor.r, skeletonColor.g * slotColor.g * attachmentColor.g,
			skeletonColor.b * slotColor.b * attachmentColor.b, skeletonColor.a * slotColor.a * attachmentColor.a);
	}
}

private typedef SkeletonRenderData = {
	var texture:Tile;
	var vertices:Array<Float>;
	var uvs:Array<Float>;
	var indices:Array<Int>;
	var blendMode:spine.BlendMode;
	var premultipliedAlpha:Bool;
	var color:Color;
};
